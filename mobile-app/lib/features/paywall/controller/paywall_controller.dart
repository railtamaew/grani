import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import '../../../services/checkout_browser_service.dart';

import '../../../config/subscription_products.dart';
import '../../../services/analytics_service.dart';
import '../../../services/auth_service.dart';
import '../../../services/subscription_service.dart';
import '../../../services/regional_checkout_service.dart';
import '../model/regional_checkout.dart';
import '../model/paywall_ui_state.dart';
import '../model/tariff_ui_model.dart';
import '../pricing/google_play_price_math.dart';

typedef PaywallNoticeCallback = void Function(PaywallNotice notice);

enum PaywallNotice { purchaseCanceled, purchasePending, purchaseError }

class PaywallController extends ChangeNotifier {
  PaywallController({
    required SubscriptionService subscriptionService,
    required AuthService authService,
    required this.locale,
    required this.defaultPlanId,
    required this.paywallSource,
    required this.trialState,
    required this.appLanguage,
    required this.onEntitlementGranted,
    this.onWebsitePurchaseReturn,
    this.onNotice,
    AnalyticsService? analyticsService,
    RegionalCheckoutService? regionalCheckoutService,
    Future<bool> Function(Uri)? openExternalCheckout,
    Future<bool> Function()? canOpenExternalCheckout,
    bool Function()? isExternalCheckoutActive,
    Stream<void>? checkoutBrowserClosed,
    this.experimentVariant = 'control',
  })  : _subscriptionService = subscriptionService,
        _authService = authService,
        _regional = regionalCheckoutService ??
            (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows
                ? RegionalCheckoutService.website(
                    request: authService.regionalBillingRequest)
                : RegionalCheckoutService.origin(
                    request: authService.regionalBillingRequest)),
        _openExternalCheckout = openExternalCheckout ?? _openBrowser,
        _canOpenExternalCheckout = canOpenExternalCheckout ??
            CheckoutBrowserService.instance.canLaunch,
        _isExternalCheckoutActive = isExternalCheckoutActive ??
            (() => CheckoutBrowserService.instance.isActive),
        _analytics = analyticsService ?? AnalyticsService(),
        _state = PaywallUiState(experimentVariant: experimentVariant) {
    _browserSubscription =
        (checkoutBrowserClosed ?? CheckoutBrowserService.instance.closed)
            .listen((_) {
      if (!_disposed && _state.externalCheckout) unawaited(onAppResumed());
    });
  }

  final SubscriptionService _subscriptionService;
  final AuthService _authService;
  final AnalyticsService _analytics;
  final RegionalCheckoutService _regional;
  final Future<bool> Function(Uri) _openExternalCheckout;
  final Future<bool> Function() _canOpenExternalCheckout;
  final bool Function() _isExternalCheckoutActive;
  static Future<bool> _openBrowser(Uri uri) =>
      CheckoutBrowserService.instance.open(uri);
  StreamSubscription<void>? _browserSubscription;
  Future<void>? _resumeInFlight;
  final String locale;
  final String defaultPlanId;
  final String paywallSource;
  final String trialState;
  final String appLanguage;
  final String experimentVariant;
  final Future<void> Function() onEntitlementGranted;
  final Future<void> Function()? onWebsitePurchaseReturn;
  final PaywallNoticeCallback? onNotice;

  PaywallUiState _state;
  PaywallUiState get state => _state;
  DateTime? get checkoutLinkExpiresAt => _regional.handoffExpiresAt;

  StreamSubscription<BillingPurchaseEvent>? _purchaseSubscription;
  Stopwatch? _ctaStopwatch;
  bool _initialized = false;
  bool _verificationInFlight = false;
  bool _disposed = false;
  RegionalOrder? _externalOrder;
  String _externalEnvironment = 'sandbox';
  String? _checkoutAccountId;
  final Map<int, String> _externalKeys = {};
  final Set<String> _reportedExternalOrders = {};
  Timer? _externalPoll;
  bool _externalCheckInFlight = false;
  bool _foreground = true;
  int _externalPollAttempts = 0;
  bool _restoreWebsitePlan = true;

  Future<void> initialize({bool reconnectStore = false}) async {
    if (_initialized) return;
    _initialized = true;
    if (_checkoutAccountId != _authService.user?.id) {
      _externalKeys.clear();
      _reportedExternalOrders.clear();
      _externalOrder = null;
      _externalPoll?.cancel();
      _restoreWebsitePlan = true;
    }
    _checkoutAccountId = _authService.user?.id;
    _purchaseSubscription =
        _subscriptionService.purchaseEvents.listen(_handlePurchaseEvent);
    final loadStopwatch = Stopwatch()..start();
    _emit(_state.copyWith(
      productsState: PaywallProductsState.loading,
      billingState: PaywallBillingState.ready,
      clearError: true,
    ));
    if (_regional.requiresStoreCountry) {
      await _subscriptionService.initialize(reconnectStore: reconnectStore);
    }
    if (_disposed) return;
    // countryCode uses the same BillingClient connection as product loading.
    // Wait for its setup/reconnection before resolving the payment method.
    final options = await _regional.resolve();
    loadStopwatch.stop();
    if (_disposed) return;

    if (options.unavailable) {
      _applyUnavailableOptions(options);
      return;
    }

    if (options.usesWata && _sameCheckoutAccount) {
      _applyExternalOptions(options);
      if (_externalEnvironment == 'production') {
        await recoverPurchases(userInitiated: false);
      }
      return;
    }

    if (!_regional.requiresStoreCountry) {
      await _subscriptionService.initialize(reconnectStore: reconnectStore);
      if (_disposed) return;
    }

    _externalPoll?.cancel();
    _externalOrder = null;
    _emit(_state.copyWith(
        externalCheckout: false,
        externalSandbox: false,
        externalPending: false,
        externalCanResume: false,
        externalReview: false));

    final plans = _buildPlans(_subscriptionService.products);
    if (!_subscriptionService.isAvailable || plans.length != 3) {
      _emit(_state.copyWith(
        productsState: PaywallProductsState.error,
        billingState: PaywallBillingState.error,
        errorKind: _subscriptionService.isAvailable
            ? PaywallErrorKind.productsUnavailable
            : PaywallErrorKind.storeUnavailable,
        timeToLoadProductsMs: loadStopwatch.elapsedMilliseconds,
      ));
      await _analytics.logPaywallEvent(
        'billing_error',
        parameters: _baseParameters(extra: <String, Object>{
          'billing_response_code': _subscriptionService.isAvailable
              ? 'products_incomplete'
              : 'store_unavailable',
          'time_to_load_products_ms': loadStopwatch.elapsedMilliseconds,
        }),
      );
      return;
    }

    final selectedId = plans.any((plan) => plan.id == defaultPlanId)
        ? defaultPlanId
        : '12_months';
    _emit(_state.copyWith(
      productsState: PaywallProductsState.ready,
      plans: plans,
      selectedPlanId: selectedId,
      billingState: PaywallBillingState.ready,
      clearError: true,
      timeToLoadProductsMs: loadStopwatch.elapsedMilliseconds,
    ));
    await _analytics.logPaywallEvent(
      'product_details_loaded',
      parameters: _baseParameters(
        plan: _state.selectedPlan,
        extra: <String, Object>{
          'product_count': plans.length,
          'time_to_load_products_ms': loadStopwatch.elapsedMilliseconds,
        },
      ),
    );
    await _analytics.logPaywallView(
        parameters: _baseParameters(
      plan: _state.selectedPlan,
      extra: <String, Object>{
        'time_to_load_products_ms': loadStopwatch.elapsedMilliseconds,
      },
    ));
    await recoverPurchases(userInitiated: false, resetIfEmpty: false);
  }

  void _applyUnavailableOptions(RegionalCheckoutOptions options) {
    _externalPoll?.cancel();
    _externalOrder = null;
    final errorKind = switch (options.unavailableReason) {
      'country_required' => PaywallErrorKind.countryUnavailable,
      'region_unavailable' ||
      'region_database_stale' ||
      'direct_connection_required' =>
        PaywallErrorKind.countryUnavailable,
      'active_subscription' => PaywallErrorKind.paymentConflict,
      'account_unverified' => PaywallErrorKind.accountUnverified,
      _ => PaywallErrorKind.regionalUnavailable,
    };
    _emit(_state.copyWith(
      productsState: PaywallProductsState.error,
      plans: const [],
      billingState: PaywallBillingState.error,
      errorKind: errorKind,
      externalCheckout: false,
      externalSandbox: false,
      externalPending: false,
      externalCanResume: false,
      externalReview: false,
    ));
  }

  Future<void> retryProducts() async {
    if (_state.isBusy) return;
    _initialized = false;
    await _purchaseSubscription?.cancel();
    _purchaseSubscription = null;
    await initialize(reconnectStore: true);
  }

  void selectPlan(String planId) {
    if (_state.productsState != PaywallProductsState.ready || _state.isBusy) {
      return;
    }
    if (_state.selectedPlanId == planId ||
        !_state.plans.any((plan) => plan.id == planId)) {
      return;
    }
    _restoreWebsitePlan = false;
    _emit(_state.copyWith(
      selectedPlanId: planId,
      externalPending: _state.externalCheckout &&
          _externalOrder?.isPending == true &&
          _state.plans.any(
              (p) => p.id == planId && p.periodDays == _externalOrder?.days),
      externalCanResume: _state.externalCheckout &&
          _externalOrder?.canOpen == true &&
          _state.plans.any(
              (p) => p.id == planId && p.periodDays == _externalOrder?.days),
      billingState: PaywallBillingState.ready,
      clearError: true,
    ));
    if (_state.externalCheckout) return;
    unawaited(_analytics.logPaywallEvent(
      'plan_selected',
      parameters: _baseParameters(plan: _state.selectedPlan),
    ));
  }

  Future<void> purchaseSelected() async {
    final plan = _state.selectedPlan;
    if (plan == null ||
        _state.productsState != PaywallProductsState.ready ||
        _state.isBusy ||
        _subscriptionService.hasPurchaseInFlight) {
      return;
    }

    if (_state.externalCheckout) {
      await _purchaseExternal(plan);
      return;
    }

    // Re-check the direct connection region before launching a new purchase.
    // A region change must show the newly selected method/price first.
    _emit(_state.copyWith(productsState: PaywallProductsState.loading));
    final options = await _regional.resolve();
    if (_disposed) return;
    if (!_sameCheckoutAccount) {
      _emit(_state.copyWith(productsState: PaywallProductsState.ready));
      await retryProducts();
      return;
    }
    if (options.unavailable) {
      _applyUnavailableOptions(options);
      return;
    }
    if (options.usesWata) {
      _applyExternalOptions(options);
      return;
    }
    _emit(_state.copyWith(productsState: PaywallProductsState.ready));
    if (_state.isBusy || _subscriptionService.hasPurchaseInFlight) return;

    _ctaStopwatch = Stopwatch()..start();
    _emit(_state.copyWith(
      billingState: PaywallBillingState.launching,
      clearError: true,
    ));
    await _analytics.logPaywallEvent(
      'purchase_cta_click',
      parameters: _baseParameters(plan: plan),
    );
    await _analytics.logPaywallEvent(
      'purchase_cta_tap',
      parameters: _baseParameters(plan: plan),
    );
    await _analytics.logPaywallEvent(
      'billing_flow_launch',
      parameters: _baseParameters(plan: plan),
    );

    final applicationUserName =
        SubscriptionService.obfuscatedAccountIdFor(_authService.user?.id);
    final launched = await _subscriptionService.launchExtensionPurchase(
      plan.productId,
      applicationUserName: applicationUserName,
    );
    if (_disposed) return;
    if (!launched) {
      _finishCtaTimer();
      _emit(_state.copyWith(
        billingState: PaywallBillingState.error,
        errorKind: _subscriptionService.isAvailable
            ? PaywallErrorKind.launchFailed
            : PaywallErrorKind.storeUnavailable,
      ));
      onNotice?.call(PaywallNotice.purchaseError);
      await _analytics.logPaywallEvent(
        'billing_error',
        parameters: _baseParameters(
          plan: plan,
          extra: const <String, Object>{
            'billing_response_code': 'launch_rejected',
          },
        ),
      );
      return;
    }

    await _analytics.logPaywallEvent(
      'billing_flow_started',
      parameters: _baseParameters(plan: plan),
    );
    _emit(_state.copyWith(
      billingState: PaywallBillingState.awaitingResult,
      clearError: true,
    ));
    await _analytics.logPaywallEvent(
      'billing_flow_opened',
      parameters: _baseParameters(plan: plan),
    );
  }

  Future<void> _handlePurchaseEvent(BillingPurchaseEvent event) async {
    if (_disposed || !SubscriptionProducts.isExtension(event.productId)) {
      return;
    }
    final plan = _planForProduct(event.productId) ?? _state.selectedPlan;
    switch (event.status) {
      case BillingPurchaseStatus.pending:
        final elapsed = _finishCtaTimer();
        await _logPurchaseResult(
          result: 'pending',
          plan: plan,
          responseCode: event.responseCode,
          elapsedMs: elapsed,
        );
        _emit(_state.copyWith(
          selectedPlanId: plan?.id,
          billingState: PaywallBillingState.pending,
          clearError: true,
        ));
        onNotice?.call(PaywallNotice.purchasePending);
        await _analytics.logPaywallEvent(
          'billing_pending',
          parameters: _baseParameters(
            plan: plan,
            extra: <String, Object>{
              if (elapsed != null) 'time_from_cta_to_result_ms': elapsed,
            },
          ),
        );
        return;
      case BillingPurchaseStatus.canceled:
        final elapsed = _finishCtaTimer();
        await _logPurchaseResult(
          result: 'canceled',
          plan: plan,
          responseCode: event.responseCode,
          elapsedMs: elapsed,
        );
        _subscriptionService.resetPendingPurchaseFlow();
        _emit(_state.copyWith(
          billingState: PaywallBillingState.ready,
          clearError: true,
        ));
        onNotice?.call(PaywallNotice.purchaseCanceled);
        await _analytics.logPaywallEvent(
          'billing_user_canceled',
          parameters: _baseParameters(
            plan: plan,
            extra: <String, Object>{
              if (elapsed != null) 'time_from_cta_to_result_ms': elapsed,
            },
          ),
        );
        return;
      case BillingPurchaseStatus.error:
        final elapsed = _finishCtaTimer();
        await _logPurchaseResult(
          result: 'error',
          plan: plan,
          responseCode: event.responseCode,
          elapsedMs: elapsed,
        );
        _subscriptionService.resetPendingPurchaseFlow();
        _emit(_state.copyWith(
          billingState: PaywallBillingState.error,
          errorKind: PaywallErrorKind.billingError,
        ));
        onNotice?.call(PaywallNotice.purchaseError);
        await _analytics.logPaywallEvent(
          'billing_error',
          parameters: _baseParameters(
            plan: plan,
            extra: <String, Object>{
              'billing_response_code': _safeResponseCode(event.responseCode),
              if (elapsed != null) 'time_from_cta_to_result_ms': elapsed,
            },
          ),
        );
        return;
      case BillingPurchaseStatus.purchased:
        await _logPurchaseResult(
          result: 'purchased',
          plan: plan,
          responseCode: event.responseCode,
          elapsedMs: _ctaStopwatch?.elapsedMilliseconds,
        );
        await _verifyPurchase(event, plan: plan);
        return;
    }
  }

  Future<void> _verifyPurchase(
    BillingPurchaseEvent event, {
    TariffUiModel? plan,
  }) async {
    if (_verificationInFlight) return;
    if (!event.hasVerificationData) {
      _emit(_state.copyWith(
        billingState: PaywallBillingState.error,
        errorKind: PaywallErrorKind.verificationFailed,
      ));
      onNotice?.call(PaywallNotice.purchaseError);
      return;
    }
    _verificationInFlight = true;
    final elapsed = _finishCtaTimer();
    _emit(_state.copyWith(
      selectedPlanId: plan?.id,
      billingState: PaywallBillingState.verifying,
      clearError: true,
    ));
    try {
      await _analytics.logPaywallEvent(
        'purchase_received',
        parameters: _baseParameters(
          plan: plan,
          extra: <String, Object>{
            if (elapsed != null) 'time_from_cta_to_result_ms': elapsed,
            if (event.recovered) 'recovered': 1,
          },
        ),
      );
      await _analytics.logPaywallEvent(
        'purchase_verification_started',
        parameters: _baseParameters(plan: plan),
      );
      final verified = await _authService.verifyGooglePlayPurchase(
        purchaseToken: event.purchaseToken!,
        productId: event.productId,
        orderId: event.orderId,
      );
      if (!verified) {
        _emit(_state.copyWith(
          billingState: PaywallBillingState.error,
          errorKind: PaywallErrorKind.verificationFailed,
        ));
        onNotice?.call(PaywallNotice.purchaseError);
        return;
      }
      await _analytics.logPaywallEvent(
        'purchase_verified',
        parameters: _baseParameters(plan: plan),
      );
      await _authService.refreshUserStatus(force: true);
      if (_disposed) return;
      await _analytics.logPaywallEvent(
        'entitlement_granted',
        parameters: _baseParameters(plan: plan),
      );
      unawaited(_analytics.logPurchaseCompleted(event.productId));
      _subscriptionService.resetPendingPurchaseFlow();
      _emit(_state.copyWith(
        billingState: PaywallBillingState.success,
        clearError: true,
      ));
      await _analytics.logPaywallEvent(
        'purchase_success_view',
        parameters: _baseParameters(plan: plan),
      );
      await Future<void>.delayed(const Duration(milliseconds: 650));
      if (!_disposed) await onEntitlementGranted();
    } finally {
      _verificationInFlight = false;
    }
  }

  Future<void> recoverPurchases({
    required bool userInitiated,
    bool resetIfEmpty = true,
  }) async {
    if (_state.externalCheckout) {
      if (_state.billingState == PaywallBillingState.success) return;
      _externalPollAttempts = 0;
      _emit(_state.copyWith(
          billingState: PaywallBillingState.verifying, clearError: true));
      try {
        if (await _refreshWebsiteEntitlement()) return;
        await _recoverWebsiteOrder();
        await _checkExternalOrder();
      } finally {
        if (!_disposed &&
            _state.billingState == PaywallBillingState.verifying) {
          _emit(_state.copyWith(billingState: PaywallBillingState.ready));
        }
      }
      _scheduleExternalPoll();
      return;
    }
    if (_state.productsState != PaywallProductsState.ready ||
        _verificationInFlight ||
        _state.billingState == PaywallBillingState.success) {
      return;
    }
    final restoreTrigger = userInitiated ? 'manual' : 'automatic';
    if (userInitiated) {
      _emit(_state.copyWith(
        billingState: PaywallBillingState.restoring,
        clearError: true,
      ));
      await _analytics.logPaywallEvent(
        'restore_purchase_tap',
        parameters: _baseParameters(plan: _state.selectedPlan),
      );
    }
    final applicationUserName =
        SubscriptionService.obfuscatedAccountIdFor(_authService.user?.id);
    final purchases = await _subscriptionService.recoverUnconsumedExtensions(
      applicationUserName: applicationUserName,
    );
    if (_disposed) return;
    if (_subscriptionService.lastRecoveryHadError) {
      if (userInitiated) {
        _emit(_state.copyWith(
          billingState: PaywallBillingState.error,
          errorKind: PaywallErrorKind.restoreFailed,
        ));
      }
      await _analytics.logPaywallEvent(
        'restore_purchase_result',
        parameters: _baseParameters(
          plan: _state.selectedPlan,
          extra: <String, Object>{
            'restore_result': 'query_error',
            'restore_trigger': restoreTrigger,
          },
        ),
      );
      return;
    }

    final pending = purchases
        .where((event) => event.status == BillingPurchaseStatus.pending)
        .toList(growable: false);
    final purchased = purchases
        .where((event) => event.status == BillingPurchaseStatus.purchased)
        .toList(growable: false);
    if (purchased.isNotEmpty) {
      await _analytics.logPaywallEvent(
        'restore_purchase_result',
        parameters: _baseParameters(
          plan: _planForProduct(purchased.first.productId),
          extra: <String, Object>{
            'restore_result': 'purchase_found',
            'restore_trigger': restoreTrigger,
          },
        ),
      );
      await _verifyPurchase(
        purchased.first,
        plan: _planForProduct(purchased.first.productId),
      );
      return;
    }
    if (pending.isNotEmpty) {
      _emit(_state.copyWith(
        selectedPlanId: _planForProduct(pending.first.productId)?.id,
        billingState: PaywallBillingState.pending,
        clearError: true,
      ));
      await _analytics.logPaywallEvent(
        'restore_purchase_result',
        parameters: _baseParameters(
          plan: _planForProduct(pending.first.productId),
          extra: <String, Object>{
            'restore_result': 'pending',
            'restore_trigger': restoreTrigger,
          },
        ),
      );
      return;
    }

    if (resetIfEmpty || userInitiated) {
      final wasAwaiting =
          _state.billingState == PaywallBillingState.awaitingResult;
      _subscriptionService.resetPendingPurchaseFlow();
      _finishCtaTimer();
      _emit(_state.copyWith(
        billingState: PaywallBillingState.ready,
        clearError: true,
      ));
      if (wasAwaiting) {
        onNotice?.call(PaywallNotice.purchaseCanceled);
        await _analytics.logPaywallEvent(
          'billing_user_canceled',
          parameters: _baseParameters(
            plan: _state.selectedPlan,
            extra: const <String, Object>{
              'billing_response_code': 'resume_query_empty',
            },
          ),
        );
      }
    }
    await _analytics.logPaywallEvent(
      'restore_purchase_result',
      parameters: _baseParameters(
        plan: _state.selectedPlan,
        extra: <String, Object>{
          'restore_result': 'nothing_to_restore',
          'restore_trigger': restoreTrigger,
        },
      ),
    );
  }

  Future<bool> _refreshWebsiteEntitlement() async {
    if (_externalEnvironment != 'production') return false;
    if (_state.billingState == PaywallBillingState.success) return true;
    // A site purchase can create an order this app has never seen.
    try {
      await _authService.refreshUserStatus(force: true);
    } catch (_) {
      return false;
    }
    if (_disposed) return true;
    if (!_sameCheckoutAccount) {
      _invalidateExternalAccount();
      return true;
    }
    // Account access may change due to another payment or a gift.
    // Success is resolved from the exact persisted checkout intent/order below.
    return false;
  }

  Future<void> _recoverWebsiteOrder() async {
    if (_externalEnvironment != 'production' ||
        !_sameCheckoutAccount ||
        _disposed) {
      return;
    }
    try {
      final hasIntent = await _regional.hasWebsiteIntent();
      final intent = hasIntent ? await _regional.websiteIntent() : null;
      final order =
          hasIntent ? intent?.order : await _regional.latestProductionOrder();
      if (!_disposed &&
          _sameCheckoutAccount &&
          _restoreWebsitePlan &&
          intent?.days != null) {
        final choices = _state.plans.where((p) => p.periodDays == intent!.days);
        if (choices.isNotEmpty)
          _emit(_state.copyWith(selectedPlanId: choices.first.id));
        _restoreWebsitePlan = false;
      }
      if (_disposed || !_sameCheckoutAccount) return;
      // A historical paid order is never success of a new purchase.
      if (hasIntent) {
        _externalOrder = order;
      } else if (order != null && !order.paid) {
        _externalOrder = order;
      }
    } catch (_) {
      // Keep the existing order on a temporary failure. Never create another.
    }
  }

  Future<void> onAppResumed() async {
    if (_disposed) return;
    final pending = _resumeInFlight;
    if (pending != null) return pending;
    final task = _resumeFromForeground();
    _resumeInFlight = task;
    try {
      await task;
    } finally {
      if (identical(_resumeInFlight, task)) _resumeInFlight = null;
    }
  }

  Future<void> _resumeFromForeground() async {
    _foreground = true;
    if (_state.externalCheckout && !_sameCheckoutAccount) {
      _invalidateExternalAccount();
      await retryProducts();
      return;
    }
    if (_state.externalCheckout) {
      if (_state.billingState == PaywallBillingState.success) return;
      _externalPollAttempts = 0;
      _emit(_state.copyWith(
          billingState: PaywallBillingState.verifying, clearError: true));
      try {
        if (_externalEnvironment == 'production' &&
            onWebsitePurchaseReturn != null &&
            await _regional.hasWebsiteIntent()) {
          await _recoverWebsiteOrder();
          if (!_disposed && _sameCheckoutAccount && _externalOrder != null) {
            await onWebsitePurchaseReturn!();
            return;
          }
        }
        if (await _refreshWebsiteEntitlement()) return;
        await _recoverWebsiteOrder();
        await _checkExternalOrder();
      } finally {
        if (!_disposed &&
            _state.billingState == PaywallBillingState.verifying) {
          _emit(_state.copyWith(billingState: PaywallBillingState.ready));
        }
      }
      if (_disposed || _state.billingState == PaywallBillingState.success) {
        return;
      }
      // Eligibility is not cached across a browser trip or account switch.
      if (!_state.isBusy) await retryProducts();
      return;
    }
    if (_state.productsState != PaywallProductsState.ready ||
        _state.billingState == PaywallBillingState.success ||
        _verificationInFlight) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await recoverPurchases(userInitiated: false);
    if (!_disposed &&
        !_state.isBusy &&
        _state.billingState != PaywallBillingState.success) {
      final options = await _regional.resolve();
      if (!_disposed && options.usesWata && _sameCheckoutAccount) {
        _applyExternalOptions(options);
      }
    }
  }

  void onAppPaused() {
    _foreground = false;
    _externalPoll?.cancel();
  }

  bool get _sameCheckoutAccount =>
      _checkoutAccountId != null && _checkoutAccountId == _authService.user?.id;

  void _invalidateExternalAccount() {
    _externalPoll?.cancel();
    _externalOrder = null;
    _externalKeys.clear();
    _externalEnvironment = 'sandbox';
    _emit(_state.copyWith(
        productsState: PaywallProductsState.error,
        billingState: PaywallBillingState.error,
        errorKind: PaywallErrorKind.launchFailed,
        externalPending: false,
        externalCanResume: false,
        externalReview: false));
  }

  void _applyExternalOptions(RegionalCheckoutOptions options) {
    if (_disposed) return;
    final plans = options.plans.map((p) => p.toTariff(locale)).toList();
    _externalEnvironment = options.environment ?? 'sandbox';
    _externalOrder = options.pendingOrder;
    final previousSelection = _state.selectedPlanId;
    final selected = plans.firstWhere((p) => p.id == previousSelection,
        orElse: () => plans.firstWhere((p) => p.id == defaultPlanId,
            orElse: () => plans.last));
    _emit(_state.copyWith(
      productsState: PaywallProductsState.ready,
      billingState: PaywallBillingState.ready,
      plans: plans,
      selectedPlanId: selected.id,
      clearError: true,
      externalCheckout: true,
      externalSandbox: _externalEnvironment == 'sandbox',
      externalPending: _externalOrder?.isPending ?? false,
      externalCanResume: _externalOrder?.canOpen ?? false,
      externalReview: _externalOrder?.needsReview ?? false,
    ));
    _scheduleExternalPoll();
  }

  /// Replaces a short-lived TV login link without opening a browser or creating
  /// a chargeable order. The website resumes the same pending order, if any.
  Future<Uri?> refreshWebsiteCheckoutLink() async {
    final plan = _state.selectedPlan;
    if (_disposed ||
        !_sameCheckoutAccount ||
        plan == null ||
        _state.isBusy ||
        !_state.externalCheckout ||
        _externalEnvironment != 'production' ||
        _state.billingState == PaywallBillingState.success) return null;
    _emit(_state.copyWith(
        billingState: PaywallBillingState.launching, clearError: true));
    try {
      final options = await _regional.resolve();
      if (_disposed ||
          !_sameCheckoutAccount ||
          !options.usesWata ||
          options.environment != 'production') return null;
      final uri = await _regional.prepareWebsiteCheckout(
          days: plan.periodDays, amountMinor: plan.priceMicros ~/ 10000);
      if (_disposed || !_sameCheckoutAccount) return null;
      _restoreWebsitePlan = true;
      return uri;
    } catch (_) {
      return null;
    } finally {
      if (!_disposed) {
        _emit(_state.copyWith(billingState: PaywallBillingState.ready));
      }
    }
  }

  Future<void> _purchaseExternal(TariffUiModel plan) async {
    if (_isExternalCheckoutActive()) return;
    if (!_sameCheckoutAccount) {
      await retryProducts();
      return;
    }
    _externalPoll?.cancel();
    _emit(_state.copyWith(
        billingState: PaywallBillingState.launching, clearError: true));
    try {
      if (!await _canOpenExternalCheckout()) {
        if (!_disposed)
          _emit(_state.copyWith(billingState: PaywallBillingState.ready));
        return;
      }
      if (_externalEnvironment == 'production') {
        // WATA approved granilink.com as the payment origin. The website
        // authenticates the same GRANI account and creates the order there.
        final options = await _regional.resolve();
        if (_disposed) return;
        if (!options.usesWata ||
            options.environment != 'production' ||
            !_sameCheckoutAccount) {
          throw const RegionalCheckoutUnavailable();
        }
        final destination = await _regional.prepareWebsiteCheckout(
            days: plan.periodDays, amountMinor: plan.priceMicros ~/ 10000);
        if (_disposed || !_sameCheckoutAccount) return;
        _restoreWebsitePlan = true;
        final opened = await _openExternalCheckout(destination);
        if (_disposed) return;
        if (!_sameCheckoutAccount) {
          _invalidateExternalAccount();
          return;
        }
        _emit(_state.copyWith(
          billingState:
              opened ? PaywallBillingState.ready : PaywallBillingState.error,
          errorKind: opened ? null : PaywallErrorKind.launchFailed,
          clearError: opened,
        ));
        return;
      }
      final key = _externalKeys.putIfAbsent(
          plan.periodDays, RegionalCheckoutService.newIdempotencyKey);
      // A fresh country check and server gate run even for a resumed order.
      final order = await _regional.create(
          days: plan.periodDays,
          amountMinor: plan.priceMicros ~/ 10000,
          idempotencyKey: key,
          expectedEnvironment: _externalEnvironment);
      if (_disposed) return;
      if (!_sameCheckoutAccount) {
        _invalidateExternalAccount();
        return;
      }
      _externalOrder = order;
      if (order.paid) {
        await _checkExternalOrder();
        return;
      }
      if (!order.canOpen) throw const RegionalCheckoutUnavailable();
      final opened = await _openExternalCheckout(order.checkoutUri!);
      if (_disposed) return;
      if (!_sameCheckoutAccount) {
        _invalidateExternalAccount();
        return;
      }
      _emit(_state.copyWith(
        billingState:
            opened ? PaywallBillingState.ready : PaywallBillingState.error,
        errorKind: opened ? null : PaywallErrorKind.launchFailed,
        clearError: opened,
        externalPending: true,
        externalCanResume: true,
        externalReview: false,
      ));
    } on RegionalCheckoutUnavailable {
      if (_disposed) return;
      _emit(_state.copyWith(
          billingState: PaywallBillingState.error,
          errorKind: PaywallErrorKind.launchFailed));
      // Re-resolve on a changed country/disabled method without automatically
      // launching a Google purchase or losing an existing paid entitlement.
      await retryProducts();
    } catch (_) {
      if (_disposed) return;
      _emit(_state.copyWith(
          billingState: PaywallBillingState.error,
          errorKind: PaywallErrorKind.launchFailed));
    } finally {
      _scheduleExternalPoll();
    }
  }

  void _scheduleExternalPoll() {
    _externalPoll?.cancel();
    if (_disposed ||
        !_foreground ||
        _externalPollAttempts >= 24 ||
        !_sameCheckoutAccount ||
        !((_externalOrder?.isPending ?? false) ||
            (_externalOrder?.needsReview ?? false))) {
      return;
    }
    _externalPoll = Timer(const Duration(seconds: 5), () async {
      _externalPollAttempts++;
      await _checkExternalOrder();
      _scheduleExternalPoll();
    });
  }

  Future<void> _checkExternalOrder() async {
    final previous = _externalOrder;
    if (previous == null ||
        _externalCheckInFlight ||
        _disposed ||
        !_sameCheckoutAccount ||
        _state.billingState == PaywallBillingState.success) {
      return;
    }
    _externalCheckInFlight = true;
    try {
      final hasIntent = _externalEnvironment == 'production' &&
          await _regional.hasWebsiteIntent();
      final order = hasIntent
          ? await _regional.websiteIntentOrder()
          : await _regional.status(previous.id,
              expectedEnvironment: _externalEnvironment);
      if (order == null) return;
      if (_disposed ||
          !_sameCheckoutAccount ||
          _externalOrder?.id != previous.id) {
        return;
      }
      _externalOrder = order;
      if (order.paid) {
        _externalPoll?.cancel();
        _emit(_state.copyWith(billingState: PaywallBillingState.verifying));
        await _authService.refreshUserStatus(force: true);
        if (_disposed) return;
        if (!_sameCheckoutAccount) {
          _invalidateExternalAccount();
          return;
        }
        if (!_authService.hasActiveSubscription) {
          _emit(_state.copyWith(
              billingState: PaywallBillingState.error,
              errorKind: PaywallErrorKind.verificationFailed));
          return;
        }
        _emit(_state.copyWith(
            billingState: PaywallBillingState.success,
            externalPending: false,
            externalCanResume: false,
            externalReview: false,
            clearError: true));
        if (_reportedExternalOrders.add(order.id)) await onEntitlementGranted();
      } else {
        if (!order.isPending) _externalKeys.remove(order.days);
        final selected = _state.selectedPlan?.periodDays == order.days;
        _emit(_state.copyWith(
            billingState: PaywallBillingState.ready,
            externalPending: selected && order.isPending,
            externalCanResume: selected && order.canOpen,
            externalReview: order.needsReview));
      }
    } catch (_) {
      // A transient status failure never grants access, loses the order, or
      // creates another payment. Retry when foregrounded or on the next poll.
      if (!_disposed &&
          (_state.billingState == PaywallBillingState.verifying ||
              _state.billingState == PaywallBillingState.launching)) {
        _emit(_state.copyWith(
            billingState: PaywallBillingState.error,
            errorKind: PaywallErrorKind.verificationFailed));
      }
    } finally {
      _externalCheckInFlight = false;
    }
  }

  List<TariffUiModel> _buildPlans(List<ProductDetails> products) {
    const definitions = <String, ({String id, int months, int days})>{
      SubscriptionProducts.extension30Days: (
        id: '1_month',
        months: 1,
        days: 30
      ),
      SubscriptionProducts.extension180Days: (
        id: '6_months',
        months: 6,
        days: 180
      ),
      SubscriptionProducts.extension365Days: (
        id: '12_months',
        months: 12,
        days: 365
      ),
    };
    final extensionProducts = <String, ProductDetails>{
      for (final product in products)
        if (definitions.containsKey(product.id)) product.id: product,
    };
    final monthlyProduct =
        extensionProducts[SubscriptionProducts.extension30Days];
    final monthlyMicros = monthlyProduct == null
        ? null
        : GooglePlayPriceMath.priceMicros(monthlyProduct);
    final plans = <TariffUiModel>[];
    for (final entry in definitions.entries) {
      final product = extensionProducts[entry.key];
      final definition = entry.value;
      if (product == null) continue;
      final micros = GooglePlayPriceMath.priceMicros(product);
      if (micros == null || micros <= 0) continue;
      final digits = GooglePlayPriceMath.fractionDigits(
        product.currencyCode,
        locale,
      );
      final sameCurrency = monthlyProduct != null &&
          monthlyProduct.currencyCode == product.currencyCode;
      final savings = sameCurrency && monthlyMicros != null
          ? GooglePlayPriceMath.savingsPercent(
              monthlyPlanPriceMicros: monthlyMicros,
              planPriceMicros: micros,
              periodMonths: definition.months,
            )
          : null;
      plans.add(TariffUiModel(
        id: definition.id,
        productId: product.id,
        periodMonths: definition.months,
        periodDays: definition.days,
        formattedMonthlyPrice: GooglePlayPriceMath.formatMonthlyPrice(
          details: product,
          priceMicros: micros,
          periodMonths: definition.months,
          locale: locale,
        ),
        formattedTotalPrice: GooglePlayPriceMath.formatTotalPrice(
          details: product,
          priceMicros: micros,
          locale: locale,
        ),
        priceMicros: micros,
        monthlyEquivalentMicros: GooglePlayPriceMath.monthlyEquivalentMicros(
          priceMicros: micros,
          periodMonths: definition.months,
          fractionDigits: digits,
        ),
        currencyCode: product.currencyCode,
        savingsPercent: savings,
        isBestValue: definition.months == 12,
        illustrationNeutral:
            'assets/images/tariffs/plan_token_${definition.months}_neutral.png',
        illustrationSelected:
            'assets/images/tariffs/plan_token_${definition.months}_selected.png',
        productDetails: product,
      ));
    }
    plans.sort((a, b) => a.periodMonths.compareTo(b.periodMonths));
    return plans;
  }

  TariffUiModel? _planForProduct(String productId) {
    for (final plan in _state.plans) {
      if (plan.productId == productId) return plan;
    }
    return null;
  }

  Map<String, Object> _baseParameters({
    TariffUiModel? plan,
    Map<String, Object>? extra,
  }) {
    final isDefault = plan?.id == defaultPlanId;
    return <String, Object>{
      if (plan != null) ...<String, Object>{
        'plan_id': plan.id,
        'product_id': plan.productId,
        'period_months': plan.periodMonths,
        'formatted_total_price': plan.formattedTotalPrice,
        'price_micros': plan.priceMicros,
        'currency_code': plan.currencyCode,
        'monthly_equivalent_micros': plan.monthlyEquivalentMicros,
        if (plan.savingsPercent != null)
          'savings_percent': plan.savingsPercent!,
        'default_selected': isDefault ? 1 : 0,
      },
      'paywall_source': paywallSource,
      'trial_state': trialState,
      'app_language': appLanguage,
      'experiment_variant': experimentVariant,
      if (extra != null) ...extra,
    };
  }

  String _safeResponseCode(String? value) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) return 'unknown';
    final safe = normalized.replaceAll(RegExp('[^a-z0-9_-]'), '_');
    return safe.substring(0, safe.length > 40 ? 40 : safe.length);
  }

  Future<void> _logPurchaseResult({
    required String result,
    TariffUiModel? plan,
    String? responseCode,
    int? elapsedMs,
  }) {
    return _analytics.logPaywallEvent(
      'purchase_result',
      parameters: _baseParameters(
        plan: plan,
        extra: <String, Object>{
          'purchase_result': result,
          'billing_response_code': _safeResponseCode(responseCode),
          if (elapsedMs != null) 'time_from_cta_to_result_ms': elapsedMs,
        },
      ),
    );
  }

  int? _finishCtaTimer() {
    final stopwatch = _ctaStopwatch;
    if (stopwatch == null) return null;
    stopwatch.stop();
    _ctaStopwatch = null;
    return stopwatch.elapsedMilliseconds;
  }

  void _emit(PaywallUiState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _browserSubscription?.cancel();
    _externalPoll?.cancel();
    _purchaseSubscription?.cancel();
    super.dispose();
  }
}

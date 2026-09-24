import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../../../config/subscription_products.dart';
import '../../../services/analytics_service.dart';
import '../../../services/auth_service.dart';
import '../../../services/subscription_service.dart';
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
    this.onNotice,
    AnalyticsService? analyticsService,
    this.experimentVariant = 'control',
  })  : _subscriptionService = subscriptionService,
        _authService = authService,
        _analytics = analyticsService ?? AnalyticsService(),
        _state = PaywallUiState(experimentVariant: experimentVariant);

  final SubscriptionService _subscriptionService;
  final AuthService _authService;
  final AnalyticsService _analytics;
  final String locale;
  final String defaultPlanId;
  final String paywallSource;
  final String trialState;
  final String appLanguage;
  final String experimentVariant;
  final Future<void> Function() onEntitlementGranted;
  final PaywallNoticeCallback? onNotice;

  PaywallUiState _state;
  PaywallUiState get state => _state;

  StreamSubscription<BillingPurchaseEvent>? _purchaseSubscription;
  Stopwatch? _ctaStopwatch;
  bool _initialized = false;
  bool _verificationInFlight = false;
  bool _disposed = false;

  Future<void> initialize({bool reconnectStore = false}) async {
    if (_initialized) return;
    _initialized = true;
    _purchaseSubscription =
        _subscriptionService.purchaseEvents.listen(_handlePurchaseEvent);
    final loadStopwatch = Stopwatch()..start();
    _emit(_state.copyWith(
      productsState: PaywallProductsState.loading,
      billingState: PaywallBillingState.ready,
      clearError: true,
    ));
    await _subscriptionService.initialize(reconnectStore: reconnectStore);
    loadStopwatch.stop();
    if (_disposed) return;

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
    _emit(_state.copyWith(
      selectedPlanId: planId,
      billingState: PaywallBillingState.ready,
      clearError: true,
    ));
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

  Future<void> onAppResumed() async {
    if (_state.productsState != PaywallProductsState.ready ||
        _state.billingState == PaywallBillingState.success ||
        _verificationInFlight) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await recoverPurchases(userInitiated: false);
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
    _purchaseSubscription?.cancel();
    super.dispose();
  }
}

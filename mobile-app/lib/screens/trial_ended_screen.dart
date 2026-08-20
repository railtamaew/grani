import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../config/app_config.dart';
import '../config/app_navigation.dart';
import '../config/subscription_products.dart';
import '../features/paywall/controller/paywall_controller.dart';
import '../features/paywall/model/paywall_ui_state.dart';
import '../features/paywall/model/tariff_ui_model.dart';
import '../features/paywall/widgets/paywall_header.dart';
import '../features/paywall/widgets/paywall_top_bar.dart';
import '../features/paywall/widgets/premium_action_surface.dart';
import '../features/paywall/widgets/tariff_card.dart';
import '../features/paywall/widgets/trust_items.dart';
import '../l10n/l10n.dart';
import '../services/auth_service.dart';
import '../services/native_vpn_service.dart';
import '../services/subscription_service.dart';
import '../services/vpn_service.dart';
import '../widgets/snackbar_utils.dart';

enum SubscriptionScreenMode { expired, upgrade, manage }

bool canDismissSubscriptionScreen(SubscriptionScreenMode mode) =>
    mode != SubscriptionScreenMode.expired;

const _subscriptionPollInterval = Duration(seconds: 25);

/// Conversion paywall for the three repeatable Google Play one-time products.
class TrialEndedScreen extends StatefulWidget {
  const TrialEndedScreen({
    super.key,
    this.mode = SubscriptionScreenMode.expired,
  });

  final SubscriptionScreenMode mode;

  @override
  State<TrialEndedScreen> createState() => _TrialEndedScreenState();
}

class _TrialEndedScreenState extends State<TrialEndedScreen>
    with RouteAware, WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static bool _entrancePlayedThisSession = false;

  late final AnimationController _entranceController;
  PaywallController? _paywallController;
  Timer? _subscriptionPollTimer;
  Timer? _androidPaymentPollTimer;
  AuthService? _authServiceForListener;
  DateTime? _androidPaymentBaselineExpiresAt;
  bool _androidPaymentBaselineActive = false;
  bool _androidPaymentDialogOpen = false;
  bool _androidPaymentCheckInFlight = false;
  int _pulseKey = 0;
  String? _lastSelectedPlanId;
  PaywallBillingState? _lastBillingState;
  bool _didConfigureEntrance = false;

  bool get _canPop => canDismissSubscriptionScreen(widget.mode);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
      value: _entrancePlayedThisSession ? 1 : 0,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeScreen());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didConfigureEntrance) return;
    _didConfigureEntrance = true;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (reducedMotion || _entrancePlayedThisSession) {
      _entranceController.value = 1;
    } else {
      _entrancePlayedThisSession = true;
      _entranceController.forward();
    }
    final route = ModalRoute.of(context);
    if (route is ModalRoute<void>) appRouteObserver.subscribe(this, route);
  }

  Future<void> _initializeScreen() async {
    if (!mounted) return;
    if (widget.mode == SubscriptionScreenMode.expired) {
      final disconnected = await _ensureVpnDisconnected();
      // The mandatory paywall must always ask the backend for the current
      // entitlement. A recent cached refresh must not strand a user here after
      // access was restored on another device or by a delayed Play callback.
      await _refreshAndNavigate(force: true);
      if (!mounted) return;
      if (disconnected) {
        showInfoSnackBar(context, context.l10n.vpnDisconnectedAccessExpired);
      }
      final auth = context.read<AuthService>();
      _authServiceForListener = auth;
      auth.addListener(_onAuthSubscriptionUpdate);
      _subscriptionPollTimer = Timer.periodic(
        _subscriptionPollInterval,
        (_) => _refreshAndNavigate(),
      );
    }
    if (!mounted || Platform.isWindows) return;
    final auth = context.read<AuthService>();
    final locale = Localizations.localeOf(context);
    final controller = PaywallController(
      subscriptionService: context.read<SubscriptionService>(),
      authService: auth,
      locale: locale.toLanguageTag(),
      defaultPlanId: AppConfig.paywallDefaultPlanId,
      paywallSource: widget.mode.name,
      trialState: widget.mode == SubscriptionScreenMode.expired
          ? 'expired'
          : auth.hasActiveSubscription
              ? 'paid_active'
              : 'trial_active',
      appLanguage: locale.languageCode,
      experimentVariant: AppConfig.paywallExperimentVariant,
      onNotice: _handleNotice,
      onEntitlementGranted: () async {
        if (!mounted) return;
        Navigator.pushNamedAndRemoveUntil(context, '/main', (_) => false);
      },
    );
    controller.addListener(_handlePaywallState);
    _paywallController = controller;
    setState(() {});
    await controller.initialize();
  }

  void _handlePaywallState() {
    final controller = _paywallController;
    if (!mounted || controller == null) return;
    final state = controller.state;
    if (_lastSelectedPlanId != null &&
        _lastSelectedPlanId != state.selectedPlanId) {
      _pulseKey++;
    }
    if (_lastBillingState != PaywallBillingState.success &&
        state.billingState == PaywallBillingState.success) {
      _pulseKey++;
      unawaited(HapticFeedback.heavyImpact());
    }
    _lastSelectedPlanId = state.selectedPlanId;
    _lastBillingState = state.billingState;
    setState(() {});
  }

  void _handleNotice(PaywallNotice notice) {
    if (!mounted) return;
    switch (notice) {
      case PaywallNotice.purchaseCanceled:
        showInfoSnackBar(context, context.l10n.paywallPaymentCanceled);
        return;
      case PaywallNotice.purchasePending:
        showInfoSnackBar(context, context.l10n.paywallPaymentPendingHint);
        return;
      case PaywallNotice.purchaseError:
        showErrorSnackBar(context, _errorText(_paywallController?.state));
        return;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_paywallController?.onAppResumed());
    }
  }

  @override
  void didPopNext() {
    unawaited(_paywallController?.onAppResumed());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    appRouteObserver.unsubscribe(this);
    _entranceController.dispose();
    _subscriptionPollTimer?.cancel();
    _androidPaymentPollTimer?.cancel();
    _authServiceForListener?.removeListener(_onAuthSubscriptionUpdate);
    _paywallController?.removeListener(_handlePaywallState);
    _paywallController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows) return _buildWindowsHandoff(context);
    final controller = _paywallController;
    final state = controller?.state ?? const PaywallUiState();
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Color(0xFFF7F9FA),
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: PopScope(
        canPop: _canPop,
        child: Scaffold(
          backgroundColor: const Color(0xFFF7F9FB),
          body: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFFFFFFF), Color(0xFFF4F7F9)],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: PaywallTopBar(
                      onBack: _canPop
                          ? () => Navigator.of(context).maybePop()
                          : null,
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        20,
                        8,
                        20,
                        18 + MediaQuery.paddingOf(context).bottom,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 480),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _entranceItem(
                                interval: const Interval(0, 0.48),
                                child: PaywallHeader(
                                  title: context.l10n.paywallChoosePlanTitle,
                                  subtitle:
                                      context.l10n.paywallChoosePlanSubtitle,
                                ),
                              ),
                              const SizedBox(height: 24),
                              if (state.productsState ==
                                  PaywallProductsState.loading)
                                for (var index = 0; index < 3; index++) ...[
                                  _entranceItem(
                                    interval: Interval(
                                      0.12 + index * 0.10,
                                      0.60 + index * 0.10,
                                      curve: Curves.easeOutCubic,
                                    ),
                                    child: const _TariffSkeleton(),
                                  ),
                                  if (index < 2) const SizedBox(height: 12),
                                ]
                              else if (state.plans.isNotEmpty)
                                for (var index = 0;
                                    index < state.plans.length;
                                    index++) ...[
                                  _entranceItem(
                                    interval: Interval(
                                      0.12 + index * 0.10,
                                      0.60 + index * 0.10,
                                      curve: Curves.easeOutCubic,
                                    ),
                                    child: _buildTariffCard(
                                      state.plans[index],
                                      state,
                                      reducedMotion,
                                    ),
                                  ),
                                  if (index < state.plans.length - 1)
                                    const SizedBox(height: 12),
                                ]
                              else
                                _PaywallError(
                                  message: _errorText(state),
                                  retryLabel: context.l10n.paywallRetry,
                                  onRetry: () => controller?.retryProducts(),
                                ),
                              const SizedBox(height: 22),
                              _entranceItem(
                                interval: const Interval(
                                  0.55,
                                  1,
                                  curve: Curves.easeOutCubic,
                                ),
                                child: PremiumActionSurface(
                                  label: _ctaLabel(state),
                                  enabled: _ctaEnabled(state),
                                  loading: state.isBusy,
                                  success: state.billingState ==
                                      PaywallBillingState.success,
                                  pulseKey: _pulseKey,
                                  reducedMotion: reducedMotion,
                                  onPressed: () =>
                                      controller?.purchaseSelected(),
                                ),
                              ),
                              if (state.billingState ==
                                  PaywallBillingState.pending) ...[
                                const SizedBox(height: 4),
                                Text(
                                  context.l10n.paywallPaymentPendingHint,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontFamily: 'Montserrat',
                                    fontSize: 13,
                                    color: Color(0xFF657487),
                                  ),
                                ),
                              ],
                              if (state.productsState ==
                                      PaywallProductsState.ready &&
                                  state.billingState ==
                                      PaywallBillingState.error) ...[
                                const SizedBox(height: 8),
                                Text(
                                  _errorText(state),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontFamily: 'Montserrat',
                                    fontSize: 13,
                                    color: Color(0xFFB64232),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 18),
                              TrustItems(
                                googlePlay: context.l10n.paywallTrustGooglePlay,
                                noRenewals: context.l10n.paywallTrustNoRenewals,
                                restore: context.l10n.paywallTrustRestore,
                              ),
                              const SizedBox(height: 8),
                              _buildLegalLinks(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTariffCard(
    TariffUiModel plan,
    PaywallUiState state,
    bool reducedMotion,
  ) {
    final selected = state.selectedPlanId == plan.id;
    final title = switch (plan.periodMonths) {
      1 => context.l10n.paywallPlanOneMonth,
      6 => context.l10n.paywallPlanSixMonths,
      _ => context.l10n.paywallPlanTwelveMonths,
    };
    final savings = plan.savingsPercent == null
        ? null
        : context.l10n.paywallSavePercent(plan.savingsPercent!);
    return TariffCard(
      plan: plan,
      selected: selected,
      enabled: !state.isBusy,
      title: title,
      perMonthLabel: context.l10n.paywallPerMonth,
      totalLabel: context.l10n.paywallTotal,
      bestValueLabel: context.l10n.paywallBestValue,
      savingsLabel: savings,
      semanticsLabel: context.l10n.paywallTariffSemantics(
        title,
        plan.formattedMonthlyPrice,
        plan.formattedTotalPrice,
        savings ?? '',
        selected
            ? context.l10n.paywallSelected
            : context.l10n.paywallNotSelected,
      ),
      reducedMotion: reducedMotion,
      onSelected: () => _paywallController?.selectPlan(plan.id),
    );
  }

  Widget _buildLegalLinks() {
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TextButton(
          onPressed: () => Navigator.pushNamed(context, '/privacy'),
          child: Text(context.l10n.paywallPrivacy),
        ),
      ],
    );
  }

  String _ctaLabel(PaywallUiState state) {
    switch (state.productsState) {
      case PaywallProductsState.loading:
        return context.l10n.paywallLoadingPlans;
      case PaywallProductsState.error:
        return context.l10n.paywallLoadingPlans;
      case PaywallProductsState.ready:
        switch (state.billingState) {
          case PaywallBillingState.launching:
          case PaywallBillingState.awaitingResult:
            return context.l10n.paywallOpeningGooglePlay;
          case PaywallBillingState.verifying:
          case PaywallBillingState.restoring:
            return context.l10n.paywallVerifyingPayment;
          case PaywallBillingState.pending:
            return context.l10n.paywallPaymentPending;
          case PaywallBillingState.success:
            return context.l10n.paywallAccessActivated;
          case PaywallBillingState.ready:
          case PaywallBillingState.error:
            final price = state.selectedPlan?.formattedTotalPrice;
            return price == null
                ? context.l10n.paywallLoadingPlans
                : context.l10n.paywallContinuePrice(price);
        }
    }
  }

  bool _ctaEnabled(PaywallUiState state) =>
      state.productsState == PaywallProductsState.ready &&
      state.selectedPlan != null &&
      !state.isBusy &&
      state.billingState != PaywallBillingState.success;

  String _errorText(PaywallUiState? state) {
    return switch (state?.errorKind) {
      PaywallErrorKind.storeUnavailable => context.l10n.paywallStoreUnavailable,
      PaywallErrorKind.productsUnavailable =>
        context.l10n.paywallProductsUnavailable,
      PaywallErrorKind.verificationFailed =>
        context.l10n.paywallVerificationFailed,
      PaywallErrorKind.restoreFailed => context.l10n.paywallRestoreFailed,
      _ => context.l10n.paywallPaymentErrorOpen,
    };
  }

  Widget _entranceItem({
    required Interval interval,
    required Widget child,
  }) {
    final curved = CurvedAnimation(
      parent: _entranceController,
      curve: interval,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, -0.025),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }

  void _onAuthSubscriptionUpdate() {
    if (!mounted) return;
    final auth = _authServiceForListener;
    if (auth == null) return;
    if (auth.hasActiveSubscription || (auth.trialSecondsLeft ?? 0) > 0) {
      _subscriptionPollTimer?.cancel();
      _subscriptionPollTimer = null;
      auth.removeListener(_onAuthSubscriptionUpdate);
      _authServiceForListener = null;
      Navigator.pushNamedAndRemoveUntil(context, '/main', (_) => false);
    }
  }

  Future<void> _refreshAndNavigate({bool force = false}) async {
    if (!mounted) return;
    final auth = context.read<AuthService>();
    await auth.refreshUserStatus(force: force);
    if (!mounted) return;
    if (auth.hasActiveSubscription || (auth.trialSecondsLeft ?? 0) > 0) {
      Navigator.pushNamedAndRemoveUntil(context, '/main', (_) => false);
    }
  }

  Future<bool> _ensureVpnDisconnected() async {
    if (!mounted) return false;
    var requested = false;
    try {
      final vpn = context.read<VpnService>();
      if (vpn.isVpnSessionPotentiallyActive) {
        requested = true;
        await vpn
            .disconnect(source: 'trial_ended_paywall')
            .timeout(const Duration(seconds: 4));
      }
    } catch (_) {}
    try {
      if (await NativeVpnService.getAmneziaWgStatus()
              .timeout(const Duration(seconds: 2)) ==
          true) {
        requested = true;
      }
      await NativeVpnService.disconnectAmneziaWg(
        reason: 'access_expired',
        source: 'trial_ended_paywall',
      ).timeout(const Duration(seconds: 4));
    } catch (_) {}
    try {
      if (await NativeVpnService.getNativeConnectionStatus()
              .timeout(const Duration(seconds: 2)) ==
          true) {
        requested = true;
      }
      await NativeVpnService.disconnect(
        reason: 'access_expired',
        source: 'trial_ended_paywall',
      ).timeout(const Duration(seconds: 4));
    } catch (_) {}
    return requested;
  }

  Widget _buildWindowsHandoff(BuildContext context) {
    final products = <({String title, String productId})>[
      (
        title: context.l10n.paywallPlanOneMonth,
        productId: SubscriptionProducts.extension30Days,
      ),
      (
        title: context.l10n.paywallPlanSixMonths,
        productId: SubscriptionProducts.extension180Days,
      ),
      (
        title: context.l10n.paywallPlanTwelveMonths,
        productId: SubscriptionProducts.extension365Days,
      ),
    ];
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FB),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PaywallHeader(
                    title: context.l10n.paywallChoosePlanTitle,
                    subtitle: context.l10n.subscriptionPayOnAndroidBody,
                  ),
                  const SizedBox(height: 24),
                  for (final product in products)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: FilledButton(
                          onPressed: () => _showPayOnAndroid(product.productId),
                          child: Text(product.title),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _androidPaymentUrl(String productId) {
    final base = Uri.parse(AppConfig.androidPaymentHandoffUrl);
    return base.replace(queryParameters: {
      ...base.queryParameters,
      'plan': productId,
    }).toString();
  }

  Future<void> _showPayOnAndroid(String productId) async {
    if (!Platform.isWindows || _androidPaymentDialogOpen) return;
    final auth = context.read<AuthService>();
    _androidPaymentBaselineActive = auth.hasActiveSubscription;
    _androidPaymentBaselineExpiresAt = auth.subscriptionExpiresAt;
    _androidPaymentDialogOpen = true;
    final handoffUrl = _androidPaymentUrl(productId);
    _androidPaymentPollTimer?.cancel();
    _androidPaymentPollTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_checkAndroidPayment(showNotFound: false)),
    );
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(context.l10n.subscriptionPayOnAndroidTitle),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(context.l10n.subscriptionPayOnAndroidBody),
                  const SizedBox(height: 16),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: QrImageView(
                        data: handoffUrl,
                        size: 220,
                        backgroundColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(context.l10n.subscriptionPayOnAndroidSameAccount),
                  const SizedBox(height: 8),
                  Text(context.l10n.subscriptionPayOnAndroidWaiting),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: handoffUrl));
                if (mounted) {
                  showInfoSnackBar(
                    context,
                    context.l10n.subscriptionPayOnAndroidLinkCopied,
                  );
                }
              },
              child: Text(context.l10n.subscriptionPayOnAndroidCopyLink),
            ),
            FilledButton(
              onPressed: () => _checkAndroidPayment(showNotFound: true),
              child: Text(context.l10n.subscriptionPayOnAndroidCheck),
            ),
          ],
        ),
      );
    } finally {
      _androidPaymentDialogOpen = false;
      _androidPaymentPollTimer?.cancel();
      _androidPaymentPollTimer = null;
    }
  }

  Future<void> _checkAndroidPayment({required bool showNotFound}) async {
    if (!_androidPaymentDialogOpen ||
        _androidPaymentCheckInFlight ||
        !mounted) {
      return;
    }
    _androidPaymentCheckInFlight = true;
    final auth = context.read<AuthService>();
    try {
      await auth.refreshUserStatus(force: true);
      if (!mounted || !_androidPaymentDialogOpen) return;
      final expiresAt = auth.subscriptionExpiresAt;
      final activated =
          !_androidPaymentBaselineActive && auth.hasActiveSubscription;
      final extended = _androidPaymentBaselineActive &&
          expiresAt != null &&
          (_androidPaymentBaselineExpiresAt == null ||
              expiresAt.isAfter(_androidPaymentBaselineExpiresAt!));
      if (activated || extended) {
        _androidPaymentDialogOpen = false;
        _androidPaymentPollTimer?.cancel();
        Navigator.of(context, rootNavigator: true).pop();
        Navigator.pushNamedAndRemoveUntil(context, '/main', (_) => false);
      } else if (showNotFound) {
        showInfoSnackBar(
          context,
          context.l10n.subscriptionPayOnAndroidNotFound,
        );
      }
    } finally {
      _androidPaymentCheckInFlight = false;
    }
  }
}

class _TariffSkeleton extends StatelessWidget {
  const _TariffSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 116,
      decoration: BoxDecoration(
        color: const Color(0xFFFBFCFD),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE3E9ED)),
      ),
      padding: const EdgeInsets.all(20),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SkeletonLine(width: 110, height: 16),
          SizedBox(height: 14),
          _SkeletonLine(width: 180, height: 24),
          SizedBox(height: 10),
          _SkeletonLine(width: 130, height: 13),
        ],
      ),
    );
  }
}

class _SkeletonLine extends StatelessWidget {
  const _SkeletonLine({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFFE8EDF0),
        borderRadius: BorderRadius.circular(height / 2),
      ),
    );
  }
}

class _PaywallError extends StatelessWidget {
  const _PaywallError({
    required this.message,
    required this.retryLabel,
    required this.onRetry,
  });

  final String message;
  final String retryLabel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7F3),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFFFD4BC)),
      ),
      child: Column(
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'Montserrat',
              fontSize: 14,
              color: Color(0xFF8A3A1A),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: onRetry, child: Text(retryLabel)),
        ],
      ),
    );
  }
}

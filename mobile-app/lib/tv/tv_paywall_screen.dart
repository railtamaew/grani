import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../features/paywall/controller/paywall_controller.dart';
import '../features/paywall/model/paywall_ui_state.dart';
import '../services/auth_service.dart';
import '../services/subscription_service.dart';
import 'tv_checkout_dialog.dart';
import 'tv_paywall_content.dart';
import 'tv_ui.dart';

class TvPaywallScreen extends StatefulWidget {
  const TvPaywallScreen({super.key});
  @override
  State<TvPaywallScreen> createState() => _TvPaywallScreenState();
}

class _TvPaywallScreenState extends State<TvPaywallScreen>
    with WidgetsBindingObserver {
  PaywallController? _controller;
  Timer? _poll;
  bool _qrOpen = false;
  bool _checking = false;
  bool _refreshing = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final auth = context.read<AuthService>();
    final language = Localizations.localeOf(context).languageCode;
    _controller = PaywallController(
      subscriptionService: context.read<SubscriptionService>(),
      authService: auth,
      locale: language,
      appLanguage: language,
      defaultPlanId: '12_months',
      paywallSource: 'android_tv',
      trialState: auth.userStatus.name,
      canOpenExternalCheckout: () async => !_qrOpen,
      isExternalCheckoutActive: () => _qrOpen,
      openExternalCheckout: _openCheckout,
      checkoutBrowserClosed: const Stream<void>.empty(),
      onEntitlementGranted: () async {
        if (!mounted) return;
        if (_qrOpen) Navigator.of(context, rootNavigator: true).pop();
        if (mounted)
          Navigator.pushNamedAndRemoveUntil(context, '/main', (_) => false);
      },
      onNotice: (notice) {
        if (!mounted) return;
        setState(
          () => _notice = switch (notice) {
            PaywallNotice.purchaseCanceled => tvText(
                context,
                'Оплата отменена.',
                'Payment canceled.',
              ),
            PaywallNotice.purchasePending => tvText(
                context,
                'Ожидаем подтверждение оплаты.',
                'Waiting for payment confirmation.',
              ),
            PaywallNotice.purchaseError => tvText(
                context,
                'Не удалось завершить оплату.',
                'Could not complete payment.',
              ),
          },
        );
      },
    );
    unawaited(_controller!.initialize());
  }

  Future<bool> _openCheckout(Uri uri) async {
    if (!mounted || _qrOpen || uri.scheme != 'https') return false;
    _qrOpen = true;
    // Return immediately so the existing controller can leave its launching
    // state, store the financial intent and recover the server-side order.
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => TvCheckoutDialog(
            uri: uri,
            expiresAt: _controller?.checkoutLinkExpiresAt,
            onCheck: _checkPayment,
            onRefresh: _refreshQr),
      ).whenComplete(() {
        _qrOpen = false;
        _poll?.cancel();
        if (mounted) unawaited(_controller!.onAppResumed());
      }),
    );
    _startPolling();
    return true;
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 6), (_) => _checkPayment());
  }

  Future<void> _checkPayment() async {
    if (_checking || _refreshing || !mounted || !_qrOpen) return;
    _checking = true;
    try {
      await _controller?.onAppResumed();
    } finally {
      _checking = false;
    }
  }

  Future<Uri?> _refreshQr() async {
    if (_checking || _refreshing || !mounted || !_qrOpen) return null;
    _refreshing = true;
    try {
      return await _controller?.refreshWebsiteCheckoutLink();
    } finally {
      _refreshing = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_controller?.onAppResumed());
      if (_qrOpen) _startPolling();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _poll?.cancel();
      _controller?.onAppPaused();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final state = controller.state;
        return TvPage(
          title: '',
          contentWidth: 460,
          actions: [
            TvButton(
                label: tvText(context, 'Аккаунт', 'Account'),
                compact: true,
                icon: Icons.person_outline_rounded,
                onPressed: () => Navigator.pushNamed(context, '/profile'))
          ],
          child: TvPaywallContent(
              state: state,
              notice: _notice,
              onSelect: controller.selectPlan,
              onPurchase: controller.purchaseSelected,
              onRetry: controller.retryProducts,
              onRestore: () =>
                  controller.recoverPurchases(userInitiated: true)),
        );
      },
    );
  }
}

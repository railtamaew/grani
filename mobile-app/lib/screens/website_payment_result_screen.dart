import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../features/paywall/controller/website_payment_result_controller.dart';
import '../services/auth_service.dart';
import '../services/regional_checkout_service.dart';

class WebsitePaymentResultScreen extends StatefulWidget {
  const WebsitePaymentResultScreen({super.key, this.controller});
  final WebsitePaymentResultController? controller;
  @override
  State<WebsitePaymentResultScreen> createState() =>
      _WebsitePaymentResultScreenState();
}

class _WebsitePaymentResultScreenState extends State<WebsitePaymentResultScreen>
    with WidgetsBindingObserver {
  WebsitePaymentResultController? _controller;
  Timer? _poll;
  int _attempts = 0;
  bool _leaving = false;
  String? _seenOrder;
  String text(String ru, String en) =>
      Localizations.localeOf(context).languageCode == 'ru' ? ru : en;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final auth = widget.controller?.auth ?? context.read<AuthService>();
      _controller = widget.controller ??
          WebsitePaymentResultController(
            auth: auth,
            service: RegionalCheckoutService(
              readCountry: () async => null,
              request: auth.regionalBillingRequest,
            ),
          );
      _controller!.addListener(_changed);
      unawaited(_controller!.refresh(reconcile: true));
      _startPoll();
    });
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    final c = _controller;
    final id = c?.order?.id;
    if (c?.paid == true &&
        c?.accessSynced == true &&
        id != null &&
        _seenOrder != id) {
      _seenOrder = id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && c!.sameAccount)
          unawaited(c.service.markPaymentResultSeen(id));
      });
    }
  }

  void _startPoll() {
    _poll?.cancel();
    _attempts = 0;
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_attempts++ >= 24 ||
          (_controller?.paid == true && _controller?.accessSynced == true)) {
        _poll?.cancel();
        return;
      }
      unawaited(_controller?.refresh(reconcile: true));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_controller?.refresh(reconcile: true));
      _startPoll();
    } else {
      _poll?.cancel();
    }
  }

  Future<void> _leave() async {
    if (_leaving || _controller == null) return;
    _leaving = true;
    final auth = _controller!.auth;
    try {
      await _controller!.acknowledgeCompleted();
    } catch (_) {}
    if (!mounted) return;
    final route = !auth.isAuthenticated
        ? '/'
        : auth.hasActiveSubscription || (auth.trialSecondsLeft ?? 0) > 0
            ? '/main'
            : '/trial-ended';
    Navigator.of(context).pushNamedAndRemoveUntil(route, (_) => false);
  }

  String? date(dynamic raw) {
    final value = DateTime.tryParse(raw?.toString() ?? '');
    if (value == null) return null;
    return DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag())
        .format(value.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final data = c?.context;
    final current = date(data?['current_paid_until']);
    final paidUntil = date(data?['order_access_until']);
    final days = data?['duration_days'];
    final amount = data?['amount_minor'];
    final activated = c?.paid == true && c?.accessSynced == true;
    final extension = data?['purchase_kind'] == 'extension';
    final title = activated
        ? text(extension ? 'Доступ продлён' : 'Premium активирован',
            extension ? 'Access extended' : 'Premium activated')
        : c?.updatingAccess == true || c?.paid == true
            ? text('Обновляем доступ', 'Updating access')
            : data?['state'] == 'refund'
                ? text('По покупке оформлен возврат', 'Purchase refunded')
                : data?['state'] == 'failed'
                    ? text('Оплата не завершена', 'Payment not completed')
                    : c?.failed == true
                        ? text('Не удалось проверить оплату',
                            'Could not check payment')
                        : data == null
                            ? c?.checked == true
                                ? text('Нет покупки для проверки',
                                    'No purchase to check')
                                : text('Проверяем покупку', 'Checking purchase')
                            : text('Платёж не подтверждён',
                                'Payment not confirmed');
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF5F8FA),
        appBar: AppBar(
          title: Text(text('Результат оплаты', 'Payment result')),
          leading:
              IconButton(icon: const Icon(Icons.arrow_back), onPressed: _leave),
        ),
        body: SafeArea(
            child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                          activated
                              ? Icons.check_circle_outline
                              : Icons.receipt_long_outlined,
                          size: 56,
                          color: activated
                              ? Colors.green
                              : const Color(0xFFFF7A00)),
                      const SizedBox(height: 20),
                      Text(title,
                          style: Theme.of(context).textTheme.headlineSmall,
                          textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      if (c?.loading == true) const LinearProgressIndicator(),
                      if (data == null && c?.loading == false)
                        Text(text(
                            'Покупку можно проверить позже. Текущий доступ сохраняется.',
                            'You can check the purchase later. Existing access is preserved.')),
                      if (days is int && amount is int) ...[
                        const SizedBox(height: 20),
                        Card(
                            child: Padding(
                                padding: const EdgeInsets.all(20),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(text('Покупка: $days дней',
                                          'Purchase: $days days')),
                                      const SizedBox(height: 8),
                                      Text(NumberFormat.currency(
                                              locale: Localizations.localeOf(
                                                      context)
                                                  .toLanguageTag(),
                                              symbol: '₽',
                                              decimalDigits: 0)
                                          .format(amount / 100)),
                                    ]))),
                      ],
                      const SizedBox(height: 16),
                      if (activated && paidUntil != null)
                        Text(
                            text('Готово — добавлено $days дней.',
                                'Done — $days days added.'),
                            textAlign: TextAlign.center),
                      if (current != null && !activated)
                        Text(text('Текущий доступ: до $current',
                            'Current access: until $current')),
                      if (c?.paid == true && paidUntil != null)
                        Text(text('Срок после этой покупки: до $paidUntil',
                            'Access after this purchase: until $paidUntil')),
                      if (c?.paid != true && data != null) ...[
                        const SizedBox(height: 12),
                        Text(text(
                            'Эта покупка ещё не добавила дни. Если деньги списаны, дождитесь подтверждения и проверьте результат. Повторять платёж не нужно.',
                            'This purchase has not added days yet. If you were charged, wait for confirmation and check again. Do not repeat the payment.')),
                      ],
                      const SizedBox(height: 28),
                      if (c?.paid != true || c?.accessSynced != true)
                        SizedBox(
                            height: 52,
                            child: OutlinedButton(
                                onPressed: c == null || c.loading
                                    ? null
                                    : () => c.refresh(reconcile: true),
                                child: Text(text(
                                    'Проверить оплату', 'Check payment')))),
                      const SizedBox(height: 12),
                      SizedBox(
                          height: 52,
                          child: FilledButton(
                              onPressed: c == null ? null : _leave,
                              child: Text(text(
                                  'Вернуться в GRANI', 'Return to GRANI')))),
                    ]))),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _controller?.removeListener(_changed);
    if (widget.controller == null) _controller?.dispose();
    super.dispose();
  }
}

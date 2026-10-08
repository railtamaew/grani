import 'dart:async';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'tv_ui.dart';

/// Shows a short-lived website login link. Refreshing it never creates an order.
class TvCheckoutDialog extends StatefulWidget {
  const TvCheckoutDialog(
      {super.key,
      required this.uri,
      required this.onCheck,
      this.onRefresh,
      this.expiresAt,
      this.now});
  final Uri uri;
  final VoidCallback onCheck;
  final Future<Uri?> Function()? onRefresh;
  final DateTime? expiresAt;
  final DateTime Function()? now;
  @override
  State<TvCheckoutDialog> createState() => _TvCheckoutDialogState();
}

class _TvCheckoutDialogState extends State<TvCheckoutDialog> {
  late Uri _uri;
  late DateTime _expiresAt;
  Timer? _ticker;
  bool _refreshing = false;
  bool _failed = false;
  final _refreshFocus = FocusNode();
  DateTime get _now => widget.now?.call() ?? DateTime.now().toUtc();
  bool get _expired => !_expiresAt.isAfter(_now);

  @override
  void initState() {
    super.initState();
    _uri = widget.uri;
    _expiresAt = widget.expiresAt ?? _now.add(const Duration(minutes: 3));
    var wasExpired = _expired;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final expired = _expired;
      setState(() {});
      if (expired && !wasExpired && widget.onRefresh != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_refreshing) _refreshFocus.requestFocus();
        });
      }
      wasExpired = expired;
    });
  }

  Future<void> _refresh() async {
    if (_refreshing || widget.onRefresh == null) return;
    setState(() {
      _refreshing = true;
      _failed = false;
    });
    // Start before the request so a slow response cannot extend the code.
    final startedAt = _now;
    Uri? replacement;
    try {
      replacement = await widget.onRefresh!();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _refreshing = false;
      if (replacement == null) {
        _failed = true;
      } else {
        _uri = replacement!;
        _expiresAt = startedAt.add(const Duration(minutes: 3));
      }
    });
    _refreshFocus.requestFocus();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _refreshFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = _expiresAt.difference(_now).inSeconds.clamp(0, 180);
    final remaining =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    return Dialog(
        child: SizedBox(
            width: 780,
            child: SingleChildScrollView(
              child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Row(children: [
                    Container(
                        width: 272,
                        height: 272,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20)),
                        child: _expired || _refreshing
                            ? const Icon(Icons.qr_code_rounded,
                                size: 150, color: Colors.grey)
                            : QrImageView(
                                key: ValueKey(_uri),
                                data: _uri.toString(),
                                size: 240,
                                backgroundColor: Colors.white)),
                    const SizedBox(width: 28),
                    Expanded(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                          Text(
                              tvText(context, 'Оплатите с телефона',
                                  'Pay on your phone'),
                              style:
                                  Theme.of(context).textTheme.headlineMedium),
                          const SizedBox(height: 14),
                          Text(
                              tvText(
                                  context,
                                  'Отсканируйте QR-код. На сайте GRANI откроется ваш аккаунт и выбранный тариф. После подтверждения оплаты доступ обновится на телевизоре.',
                                  'Scan the QR code to open your account and selected plan on the GRANI website. TV access updates after payment confirmation.'),
                              style: const TextStyle(
                                  fontSize: 18, color: tvMuted)),
                          const SizedBox(height: 12),
                          Text(_uri.host, style: const TextStyle(fontSize: 17)),
                          const SizedBox(height: 8),
                          Text(
                              _expired
                                  ? tvText(
                                      context,
                                      'QR-код истёк. Получите новый.',
                                      'QR code expired. Get a new one.')
                                  : tvText(
                                      context,
                                      'QR-код действует $remaining',
                                      'QR code valid for $remaining'),
                              style: const TextStyle(
                                  fontSize: 15, color: tvMuted)),
                          if (_failed) ...[
                            const SizedBox(height: 10),
                            Text(
                                tvText(
                                    context,
                                    'Не удалось обновить QR-код. Проверьте интернет и повторите.',
                                    'Could not refresh the QR code. Check your internet and retry.'),
                                style: const TextStyle(
                                    fontSize: 15, color: tvMuted))
                          ],
                          const SizedBox(height: 18),
                          TvButton(
                              label: tvText(
                                  context, 'Проверить оплату', 'Check payment'),
                              autofocus: !_expired,
                              primary: true,
                              onPressed: _refreshing ? null : widget.onCheck),
                          if (widget.onRefresh != null) ...[
                            const SizedBox(height: 10),
                            TvButton(
                                label: _refreshing
                                    ? tvText(context, 'Обновляем QR-код…',
                                        'Refreshing QR code…')
                                    : tvText(
                                        context, 'Новый QR-код', 'New QR code'),
                                focusNode: _refreshFocus,
                                autofocus: _expired,
                                onPressed: _refreshing
                                    ? null
                                    : () => unawaited(_refresh()))
                          ],
                          const SizedBox(height: 10),
                          TvButton(
                              label: tvText(context, 'Закрыть', 'Close'),
                              onPressed: () => Navigator.pop(context)),
                        ])),
                  ])),
            )));
  }
}

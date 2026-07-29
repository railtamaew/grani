import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../services/notification_journal_service.dart';
import '../theme.dart';

enum _JournalTone { success, info, warning, critical, update, neutral }

class _JournalToneSpec {
  const _JournalToneSpec({
    required this.accent,
    required this.background,
    required this.border,
    required this.icon,
  });

  final Color accent;
  final Color background;
  final Color border;
  final IconData icon;

  static _JournalToneSpec forTone(_JournalTone tone) {
    switch (tone) {
      case _JournalTone.success:
        return const _JournalToneSpec(
          accent: Color(0xFF2FBF7A),
          background: Color(0xFFF1FBF6),
          border: Color(0xFFD8EFE5),
          icon: Icons.check_rounded,
        );
      case _JournalTone.info:
        return const _JournalToneSpec(
          accent: Color(0xFF3A7BD5),
          background: Color(0xFFEAF2FF),
          border: Color(0xFFD6E3F8),
          icon: Icons.info_outline_rounded,
        );
      case _JournalTone.warning:
        return const _JournalToneSpec(
          accent: Color(0xFFE68A2E),
          background: Color(0xFFFFF8EA),
          border: Color(0xFFF1DFC0),
          icon: Icons.priority_high_rounded,
        );
      case _JournalTone.critical:
        return const _JournalToneSpec(
          accent: Color(0xFFE05A4F),
          background: Color(0xFFFFF0EE),
          border: Color(0xFFF0CDC8),
          icon: Icons.close_rounded,
        );
      case _JournalTone.update:
        return const _JournalToneSpec(
          accent: Color(0xFF8E5AE8),
          background: Color(0xFFF5EEFF),
          border: Color(0xFFE7D8FB),
          icon: Icons.sync_rounded,
        );
      case _JournalTone.neutral:
        return const _JournalToneSpec(
          accent: Color(0xFF7C8797),
          background: Color(0xFFF3F6F8),
          border: Color(0xFFE1E7EC),
          icon: Icons.notifications_none_rounded,
        );
    }
  }
}

/// Локальный журнал push-уведомлений (см. [NotificationJournalService]).
class NotificationJournalScreen extends StatelessWidget {
  const NotificationJournalScreen({super.key});

  String _sourceSubtitle(BuildContext context, String source) {
    final l10n = context.l10n;
    switch (source) {
      case 'fcm_foreground':
        return l10n.notificationJournalSourceForeground;
      case 'fcm_opened_app':
        return l10n.notificationJournalSourceOpenedApp;
      case 'fcm_initial_message':
        return l10n.notificationJournalSourceInitial;
      case 'fcm_background_ios':
        return l10n.notificationJournalSourceBackground;
      default:
        return source;
    }
  }

  Map<String, dynamic> _data(NotificationJournalEntry entry) {
    final raw = entry.dataJson;
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Stored notification payload is best-effort only.
    }
    return const {};
  }

  String _eventName(NotificationJournalEntry entry) {
    final data = _data(entry);
    final event = (data['event'] ?? data['type'] ?? '').toString().trim();
    return event;
  }

  _JournalTone _journalTone(NotificationJournalEntry entry) {
    switch (_eventName(entry)) {
      case 'payment_completed':
      case 'subscription_activated':
      case 'access_changed':
        return _JournalTone.success;
      case 'trial_activated':
        return _JournalTone.info;
      case 'payment_failed':
      case 'subscription_expiry_warning':
      case 'trial_expiry_warning':
      case 'trial_ending':
        return _JournalTone.warning;
      case 'subscription_expired':
      case 'subscription_revoked':
      case 'trial_ended':
      case 'device_limit':
      case 'device_limit_exceeded':
      case 'device_revoked':
        return _JournalTone.critical;
      case 'app_update_available':
      case 'update_available':
        return _JournalTone.update;
    }

    final title = entry.title.trim().toLowerCase();
    if (title.contains('payment received') ||
        title.contains('оплата получена') ||
        title.contains('access updated') ||
        title.contains('доступ обнов')) {
      return _JournalTone.success;
    }
    if (title.contains('trial access') ||
        title.contains('пробный доступ подключ')) {
      return _JournalTone.info;
    }
    if (title.contains('failed') ||
        title.contains('не прошла') ||
        title.contains('expiring soon') ||
        title.contains('скоро')) {
      return _JournalTone.warning;
    }
    if (title.contains('expired') ||
        title.contains('revoked') ||
        title.contains('device limit') ||
        title.contains('лимит устройств') ||
        title.contains('истек') ||
        title.contains('истёк') ||
        title.contains('отозвана') ||
        title.contains('заверш')) {
      return _JournalTone.critical;
    }
    if (title.contains('update') || title.contains('обновлен')) {
      return _JournalTone.update;
    }
    return _JournalTone.neutral;
  }

  bool _isRu(BuildContext context) {
    return Localizations.localeOf(context).languageCode == 'ru';
  }

  String? _dateFromDataOrText(Map<String, dynamic> data, String text) {
    for (final key in const [
      'expires_at',
      'expiresAt',
      'expires',
      'valid_until',
      'validUntil',
      'until',
    ]) {
      final raw = data[key]?.toString().trim();
      if (raw == null || raw.isEmpty) continue;
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) {
        return DateFormat('dd.MM.yyyy').format(parsed.toLocal());
      }
      final match = RegExp(r'\d{2}\.\d{2}\.\d{4}').firstMatch(raw);
      if (match != null) return match.group(0);
    }

    final dateMatch = RegExp(r'\d{2}\.\d{2}\.\d{4}').firstMatch(text);
    if (dateMatch != null) return dateMatch.group(0);
    final isoMatch = RegExp(r'\d{4}-\d{2}-\d{2}').firstMatch(text);
    if (isoMatch != null) {
      final parsed = DateTime.tryParse(isoMatch.group(0)!);
      if (parsed != null) return DateFormat('dd.MM.yyyy').format(parsed);
    }
    return null;
  }

  String _premiumUntilBody(
      BuildContext context, Map<String, dynamic> data, String storedBody) {
    final date = _dateFromDataOrText(data, storedBody);
    if (date == null) {
      return _isRu(context)
          ? 'Премиум активен. Можно подключаться.'
          : 'Premium is active. You can connect now.';
    }
    return _isRu(context)
        ? 'Премиум активен до $date'
        : 'Premium active until $date';
  }

  String _localizedTitle(BuildContext context, NotificationJournalEntry entry) {
    final l10n = context.l10n;
    final event = _data(entry)['event']?.toString().trim();
    switch (event) {
      case 'payment_completed':
        return l10n.notificationJournalFallbackPaymentCompletedTitle;
      case 'payment_failed':
        return l10n.paymentFailedTitle;
      case 'subscription_activated':
        return l10n.subscriptionActivatedTitle;
      case 'subscription_revoked':
        return l10n.notificationJournalFallbackSubscriptionRevokedTitle;
      case 'subscription_expired':
        return l10n.notificationJournalFallbackSubscriptionExpiredTitle;
      case 'subscription_expiry_warning':
        return l10n.notificationJournalFallbackSubscriptionExpiryWarningTitle;
      case 'access_changed':
        return _isRu(context) ? 'Доступ обновлён' : 'Access updated';
      case 'device_limit':
      case 'device_limit_exceeded':
        return _isRu(context)
            ? 'Превышен лимит устройств'
            : 'Device limit exceeded';
      case 'device_revoked':
        return _isRu(context) ? 'Устройство удалено' : 'Device removed';
      case 'trial_activated':
        return l10n.notificationJournalFallbackTrialActivatedTitle;
      case 'trial_ended':
        return l10n.notificationJournalFallbackTrialEndedTitle;
    }

    if (Localizations.localeOf(context).languageCode != 'ru') {
      switch (entry.title.trim().toLowerCase()) {
        case 'оплата получена':
          return 'Payment received';
        case 'доступ обновлён':
          return 'Access updated';
        case 'превышен лимит устройств':
          return 'Device limit exceeded';
        case 'подписка истекла':
          return 'Subscription expired';
        case 'подписка отозвана':
          return 'Subscription revoked';
        case 'подписка скоро истечёт':
          return 'Subscription expires soon';
        case 'пробный доступ подключён':
          return 'Trial access enabled';
        case 'пробный период завершён':
          return 'Trial period ended';
        case 'оплата не прошла':
          return 'Payment failed';
        case 'устройство удалено':
          return 'Device removed';
      }
      return entry.title;
    }
    switch (entry.title.trim().toLowerCase()) {
      case 'payment received':
        return l10n.notificationJournalFallbackPaymentCompletedTitle;
      case 'subscription expired':
        return l10n.notificationJournalFallbackSubscriptionExpiredTitle;
      case 'subscription cancelled':
      case 'subscription revoked':
        return l10n.notificationJournalFallbackSubscriptionRevokedTitle;
      case 'subscription expiring soon':
        return l10n.notificationJournalFallbackSubscriptionExpiryWarningTitle;
      case 'trial ended':
        return l10n.notificationJournalFallbackTrialEndedTitle;
      case 'trial access enabled':
        return l10n.notificationJournalFallbackTrialActivatedTitle;
      default:
        return entry.title;
    }
  }

  String _localizedBody(BuildContext context, NotificationJournalEntry entry) {
    final data = _data(entry);
    final event = data['event']?.toString().trim();
    final l10n = context.l10n;
    final locale = Localizations.localeOf(context).languageCode;

    switch (event) {
      case 'payment_completed':
      case 'subscription_activated':
        return _premiumUntilBody(context, data, entry.body);
      case 'payment_failed':
        return l10n.paymentFailedBody;
      case 'subscription_revoked':
        return l10n.notificationJournalFallbackSubscriptionRevokedBody;
      case 'subscription_expired':
        return l10n.notificationJournalFallbackSubscriptionExpiredBody;
      case 'subscription_expiry_warning':
        return l10n.notificationJournalFallbackSubscriptionExpiryWarningBody;
      case 'access_changed':
        return locale == 'ru'
            ? 'Статус подписки синхронизирован. Доступ к VPN актуален.'
            : 'Subscription status synced. VPN access is up to date.';
      case 'device_limit':
      case 'device_limit_exceeded':
        return locale == 'ru'
            ? 'Удалите лишнее устройство, чтобы продолжить пользоваться VPN.'
            : 'Remove an extra device to continue using VPN.';
      case 'device_revoked':
        return locale == 'ru'
            ? 'Это устройство больше не привязано к аккаунту.'
            : 'This device is no longer linked to the account.';
      case 'trial_activated':
        return locale == 'ru'
            ? 'Вам подключён пробный доступ на 1 ч. Можно подключаться.'
            : 'Trial access is enabled for 1 hour. You can connect now.';
      case 'trial_ended':
        return l10n.notificationJournalFallbackTrialEndedBody;
      default:
        break;
    }

    if (entry.body.trim().isNotEmpty && entry.body != '—') {
      if (locale == 'ru') {
        return _normalizeRussianStoredBody(entry.body);
      }
      return _normalizeEnglishStoredBody(entry.body);
    }
    return entry.body;
  }

  String _normalizeRussianStoredBody(String body) {
    var value = body.trim();
    value = value
        .replaceAll(
            'Your subscription has been extended.', 'Подписка продлена.')
        .replaceAll('Renew in the GRANI app to restore VPN access.',
            'Продлите подписку в приложении GRANI.')
        .replaceAll('VPN access is paused. Subscribe again to continue.',
            'Доступ к VPN приостановлен. Оформите подписку снова.')
        .replaceAll('Renew before the end date to keep access.',
            'Продлите подписку до даты окончания, чтобы сохранить доступ.')
        .replaceAll('Subscribe to continue using GRANI.',
            'Оформите подписку, чтобы продолжить пользоваться GRANI.')
        .replaceAll('You can connect now.', 'Можно подключаться.');

    final match =
        RegExp(r'^["«](.+?)["»]\s+extended until\s+(.+)$').firstMatch(value);
    if (match != null) {
      return '«${match.group(1)}» продлена до ${match.group(2)}';
    }
    return value;
  }

  String _normalizeEnglishStoredBody(String body) {
    var value = body.trim();
    value = value
        .replaceAll('Вам подключён пробный доступ на 1 ч. Можно подключаться.',
            'Trial access is enabled for 1 hour. You can connect now.')
        .replaceAll(
            'Удалите лишнее устройство, чтобы продолжить пользоваться VPN.',
            'Remove an extra device to continue using VPN.')
        .replaceAll('Статус подписки синхронизирован. Доступ к VPN актуален.',
            'Subscription status synced. VPN access is up to date.')
        .replaceAll('Оформите подписку, чтобы продолжить пользоваться GRANI',
            'Subscribe to continue using GRANI.')
        .replaceAll('Продлите подписку в приложении GRANI',
            'Renew in the GRANI app to restore VPN access.')
        .replaceAll('Проверьте способ оплаты и попробуйте снова',
            'Check your payment method and try again.')
        .replaceAll('Платная подписка активна, VPN-доступ сохранён',
            'Paid subscription is active, VPN access is preserved.');
    final premiumDate =
        RegExp(r'Премиум активен до\s+(\d{2}\.\d{2}\.\d{4})').firstMatch(value);
    if (premiumDate != null) {
      return 'Premium active until ${premiumDate.group(1)}';
    }
    return value;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final dateFmt = DateFormat('dd.MM.yyyy HH:mm');

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Color(0xFFFFFFFF),
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Color(0xFFF7F9FA),
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: GraniTheme.devicesScreenBackgroundGradient,
          ),
          child: SafeArea(
            child: Column(
              children: [
                AppBar(
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  leading: IconButton(
                    icon: const Icon(Icons.arrow_back,
                        color: GraniTheme.primaryText),
                    onPressed: () => Navigator.pop(context),
                  ),
                  centerTitle: true,
                  title: Text(
                    l10n.notificationJournalScreenTitle,
                    style: GraniTheme.bodyMedium.copyWith(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      color: GraniTheme.primaryText,
                    ),
                  ),
                  actions: [
                    Consumer<NotificationJournalService>(
                      builder: (context, svc, _) {
                        if (svc.entries.isEmpty) return const SizedBox.shrink();
                        return TextButton(
                          onPressed: () async {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                backgroundColor: GraniTheme.surfaceSoft,
                                title: Text(
                                  l10n.notificationJournalClearTitle,
                                  style: GraniTheme.bodyMedium
                                      .copyWith(fontWeight: FontWeight.w600),
                                ),
                                content: Text(
                                  l10n.notificationJournalClearConfirm,
                                  style: GraniTheme.bodyMedium
                                      .copyWith(fontSize: 14),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: Text(
                                      MaterialLocalizations.of(ctx)
                                          .cancelButtonLabel,
                                      style: const TextStyle(
                                          color: GraniTheme.secondaryText),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: Text(
                                      l10n.notificationJournalClear,
                                      style: const TextStyle(
                                        color: GraniTheme.destructiveRed,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                            if (ok == true && context.mounted) {
                              await svc.clearAll();
                            }
                          },
                          child: Text(
                            l10n.notificationJournalClear,
                            style: const TextStyle(
                              color: GraniTheme.destructiveRed,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
                Expanded(
                  child: Consumer<NotificationJournalService>(
                    builder: (context, svc, _) {
                      if (svc.entries.isEmpty) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.notifications_none_outlined,
                                  size: 72,
                                  color: Colors.grey[400],
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  l10n.notificationJournalEmpty,
                                  textAlign: TextAlign.center,
                                  style: GraniTheme.bodyMedium.copyWith(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                    color: GraniTheme.primaryText,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  l10n.notificationJournalEmptySubtitle,
                                  textAlign: TextAlign.center,
                                  style: GraniTheme.bodyMedium.copyWith(
                                    fontSize: 14,
                                    color: GraniTheme.secondaryText,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }
                      return ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        itemCount: svc.entries.length,
                        itemBuilder: (context, i) {
                          final e = svc.entries[i];
                          final title = _localizedTitle(context, e);
                          final body = _localizedBody(context, e);
                          final toneSpec =
                              _JournalToneSpec.forTone(_journalTone(e));
                          return Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            decoration: GraniTheme.graniSurfaceDecoration(
                              radius: GraniTheme.profileCardRadius,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: toneSpec.background,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: toneSpec.border,
                                      ),
                                    ),
                                    child: Icon(
                                      toneSpec.icon,
                                      color: toneSpec.accent,
                                      size: 24,
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          title,
                                          style: GraniTheme.bodyMedium.copyWith(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 16,
                                            color: GraniTheme.primaryText,
                                          ),
                                        ),
                                        if (body.isNotEmpty && body != '—') ...[
                                          const SizedBox(height: 6),
                                          Text(
                                            body,
                                            style:
                                                GraniTheme.bodyMedium.copyWith(
                                              fontSize: 14,
                                              color: GraniTheme.primaryText,
                                              height: 1.35,
                                            ),
                                          ),
                                        ],
                                        const SizedBox(height: 10),
                                        Text(
                                          '${dateFmt.format(e.receivedAt)} · ${_sourceSubtitle(context, e.source)}',
                                          style: GraniTheme.bodySmall.copyWith(
                                            color: GraniTheme.secondaryText,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

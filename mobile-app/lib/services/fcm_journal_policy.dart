import 'package:firebase_messaging/firebase_messaging.dart';

import '../l10n/app_localizations.dart';
import 'entitlement_push_contract.dart';

/// Какие FCM [data.event] попадают в локальный журнал (и баннер в foreground).
/// Совпадает с бэкендом [notification_service._push].
class FcmJournalPolicy {
  FcmJournalPolicy._();

  static const Set<String> productDataEvents = {
    'payment_completed',
    'payment_failed',
    'subscription_revoked',
    'subscription_activated',
    'subscription_expiry_warning',
    'subscription_expired',
    'access_changed',
    'device_limit',
    'device_limit_exceeded',
    'device_revoked',
    'trial_activated',
    'trial_ended',
    'lifecycle_message',
  };

  static bool shouldAppendToJournal(RemoteMessage message) {
    final raw = message.data['event']?.toString().trim() ?? '';
    return raw.isNotEmpty && productDataEvents.contains(raw);
  }

  /// Заголовок и текст для журнала / локального баннера (язык из [l10n]).
  static ({String title, String body}) titlesForMessage(
    RemoteMessage message,
    AppLocalizations l10n,
  ) {
    final data = Map<String, dynamic>.from(message.data);
    final notificationBody = (message.notification?.body ?? '').trim();
    final event = (data['event'] ?? '').toString().trim();
    switch (event) {
      case 'payment_completed':
        return (
          title: l10n.notificationJournalFallbackPaymentCompletedTitle,
          body: _premiumUntilBody(data, notificationBody, l10n),
        );
      case 'payment_failed':
        return (title: l10n.paymentFailedTitle, body: l10n.paymentFailedBody);
      case 'subscription_activated':
        return (
          title: l10n.subscriptionActivatedTitle,
          body: _premiumUntilBody(data, notificationBody, l10n),
        );
      case 'subscription_revoked':
        return (
          title: l10n.notificationJournalFallbackSubscriptionRevokedTitle,
          body: l10n.notificationJournalFallbackSubscriptionRevokedBody,
        );
      case 'subscription_expired':
        return (
          title: l10n.notificationJournalFallbackSubscriptionExpiredTitle,
          body: l10n.notificationJournalFallbackSubscriptionExpiredBody,
        );
      case 'subscription_expiry_warning':
        return (
          title: l10n.notificationJournalFallbackSubscriptionExpiryWarningTitle,
          body: l10n.notificationJournalFallbackSubscriptionExpiryWarningBody,
        );
      case 'access_changed':
        final isRu = l10n.localeName.toLowerCase().startsWith('ru');
        return (
          title: isRu ? 'Доступ обновлён' : 'Access updated',
          body: isRu
              ? 'Статус подписки синхронизирован. Доступ к VPN актуален.'
              : 'Subscription status synced. VPN access is up to date.',
        );
      case 'device_limit':
      case 'device_limit_exceeded':
        final isRu = l10n.localeName.toLowerCase().startsWith('ru');
        return (
          title: isRu ? 'Превышен лимит устройств' : 'Device limit exceeded',
          body: isRu
              ? 'Удалите лишнее устройство, чтобы продолжить пользоваться VPN.'
              : 'Remove an extra device to continue using VPN.',
        );
      case 'device_revoked':
        final isRu = l10n.localeName.toLowerCase().startsWith('ru');
        return (
          title: isRu ? 'Устройство удалено' : 'Device removed',
          body: isRu
              ? 'Это устройство больше не привязано к аккаунту.'
              : 'This device is no longer linked to the account.',
        );
      case 'trial_activated':
        return (
          title: l10n.notificationJournalFallbackTrialActivatedTitle,
          body: l10n.notificationJournalFallbackTrialActivatedBody,
        );
      case 'trial_ended':
        return (
          title: l10n.notificationJournalFallbackTrialEndedTitle,
          body: l10n.notificationJournalFallbackTrialEndedBody,
        );
      default:
        break;
    }

    final n = message.notification;
    if (n != null &&
        ((n.title ?? '').trim().isNotEmpty ||
            (n.body ?? '').trim().isNotEmpty)) {
      return (
        title: (n.title ?? l10n.notificationJournalDataPayloadTitle).trim(),
        body: (n.body ?? '').trim(),
      );
    }

    if (EntitlementPushContract.mapRequestsVpnStop(data)) {
      final reasonRaw =
          data[EntitlementPushContract.reasonKey]?.toString().trim();
      final r = (reasonRaw == null || reasonRaw.isEmpty) ? '—' : reasonRaw;
      return (
        title: l10n.notificationJournalPushStopTitle,
        body: l10n.notificationJournalPushStopBody(r),
      );
    }
    final summary = data.entries.map((e) => '${e.key}=${e.value}').join(', ');
    if (summary.isEmpty) {
      return (
        title: l10n.notificationJournalDataPayloadTitle,
        body: '—',
      );
    }
    return (
      title: l10n.notificationJournalDataPayloadTitle,
      body: l10n.notificationJournalDataPayloadBody(summary),
    );
  }

  static String _premiumUntilBody(
    Map<String, dynamic> data,
    String notificationBody,
    AppLocalizations l10n,
  ) {
    final isRu = l10n.localeName.toLowerCase().startsWith('ru');
    final date = _dateFromDataOrText(data, notificationBody);
    if (date == null) {
      return isRu
          ? 'Премиум активен. Можно подключаться.'
          : 'Premium is active. You can connect now.';
    }
    return isRu ? 'Премиум активен до $date' : 'Premium active until $date';
  }

  static String? _dateFromDataOrText(
    Map<String, dynamic> data,
    String text,
  ) {
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
        return _formatDate(parsed.toLocal());
      }
      final match = RegExp(r'\d{2}\.\d{2}\.\d{4}').firstMatch(raw);
      if (match != null) return match.group(0);
    }
    final displayDate = RegExp(r'\d{2}\.\d{2}\.\d{4}').firstMatch(text);
    if (displayDate != null) return displayDate.group(0);
    final isoDate = RegExp(r'\d{4}-\d{2}-\d{2}').firstMatch(text);
    if (isoDate != null) {
      final parsed = DateTime.tryParse(isoDate.group(0)!);
      if (parsed != null) return _formatDate(parsed);
    }
    return null;
  }

  static String _formatDate(DateTime value) {
    final day = value.day.toString().padLeft(2, '0');
    final month = value.month.toString().padLeft(2, '0');
    final year = value.year.toString().padLeft(4, '0');
    return '$day.$month.$year';
  }
}

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
    'trial_activated',
    'trial_ended',
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
    final n = message.notification;
    if (n != null &&
        ((n.title ?? '').trim().isNotEmpty ||
            (n.body ?? '').trim().isNotEmpty)) {
      return (
        title: (n.title ?? l10n.notificationJournalDataPayloadTitle).trim(),
        body: (n.body ?? '').trim(),
      );
    }

    final event = (data['event'] ?? '').toString().trim();
    switch (event) {
      case 'payment_completed':
        return (
          title: l10n.notificationJournalFallbackPaymentCompletedTitle,
          body: l10n.notificationJournalFallbackPaymentCompletedBody,
        );
      case 'payment_failed':
        return (title: l10n.paymentFailedTitle, body: l10n.paymentFailedBody);
      case 'subscription_activated':
        return (
          title: l10n.subscriptionActivatedTitle,
          body: l10n.subscriptionActivatedSubtitle,
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
}

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../services/notification_journal_service.dart';
import '../theme.dart';

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
      case 'trial_activated':
        return l10n.notificationJournalFallbackTrialActivatedTitle;
      case 'trial_ended':
        return l10n.notificationJournalFallbackTrialEndedTitle;
    }

    if (Localizations.localeOf(context).languageCode != 'ru') {
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

    if (entry.body.trim().isNotEmpty && entry.body != '—') {
      if (locale == 'ru') {
        return _normalizeRussianStoredBody(entry.body);
      }
      return entry.body;
    }

    switch (event) {
      case 'payment_completed':
        return l10n.notificationJournalFallbackPaymentCompletedBody;
      case 'payment_failed':
        return l10n.paymentFailedBody;
      case 'subscription_activated':
        return l10n.subscriptionActivatedSubtitle;
      case 'subscription_revoked':
        return l10n.notificationJournalFallbackSubscriptionRevokedBody;
      case 'subscription_expired':
        return l10n.notificationJournalFallbackSubscriptionExpiredBody;
      case 'subscription_expiry_warning':
        return l10n.notificationJournalFallbackSubscriptionExpiryWarningBody;
      case 'trial_activated':
        return l10n.notificationJournalFallbackTrialActivatedBody;
      case 'trial_ended':
        return l10n.notificationJournalFallbackTrialEndedBody;
      default:
        return entry.body;
    }
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
                                      gradient:
                                          GraniTheme.surfaceControlGradient,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: GraniTheme.surfaceControlBorder
                                            .withOpacity(0.72),
                                      ),
                                    ),
                                    child: const Icon(
                                      Icons.mark_email_read_outlined,
                                      color: GraniTheme.xrayActive,
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

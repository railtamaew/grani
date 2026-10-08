import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../models/profile_access_snapshot.dart';
import '../../theme.dart';
import 'grani_gift_section.dart';
import 'grani_access_avatar.dart';
import 'profile_ui_kit.dart';

/// Menu presentation shared by the drawer and visual/widget acceptance tests.
/// Callbacks stay in the drawer; this widget cannot change entitlements.
class GraniMenuSections extends StatelessWidget {
  const GraniMenuSections(
      {super.key,
      required this.access,
      required this.now,
      required this.email,
      required this.version,
      required this.language,
      required this.onPlan,
      required this.onShare,
      required this.onReceive,
      required this.onBonuses,
      required this.onLanguage,
      required this.onSplitTunnel,
      required this.onDevices,
      required this.onNotifications,
      required this.onSupport,
      required this.onCopyEmail,
      required this.onCopyVersion,
      this.avatarAccountKey = '',
      this.deviceCount,
      this.deviceLimit = 5,
      this.deviceError = false,
      this.showSplitTunnel = true});

  final ProfileAccessSnapshot access;
  final DateTime now;
  final String email, version, language;
  final String avatarAccountKey;
  final int? deviceCount;
  final int deviceLimit;
  final bool deviceError, showSplitTunnel;
  final VoidCallback onPlan,
      onShare,
      onReceive,
      onBonuses,
      onLanguage,
      onSplitTunnel,
      onDevices,
      onNotifications,
      onSupport,
      onCopyEmail,
      onCopyVersion;

  @override
  Widget build(BuildContext context) {
    final ru = Localizations.localeOf(context).languageCode == 'ru';
    String copy(String russian, String english) => ru ? russian : english;
    Widget section(String key, String title, String icon, Widget card) =>
        Column(
            key: ValueKey(key),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GraniSectionHeader(
                  title: title,
                  iconSvg: icon,
                  icon: key == 'profile-section-settings'
                      ? Icons.tune
                      : key == 'profile-section-gifts'
                          ? Icons.redeem
                          : null),
              const SizedBox(height: 10),
              card
            ]);
    Widget row(String key, String icon, String title, VoidCallback onTap,
            {String? subtitle,
            String? semantics,
            IconData trailing = Icons.chevron_right}) =>
        GraniSectionRow(
            key: ValueKey(key),
            iconSvg: icon,
            onTap: onTap,
            semanticLabel: semantics ?? title,
            trailingIcon: trailing,
            labelWidget:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: GraniTheme.bodyMedium.copyWith(
                      fontSize: 14.5,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                      color: GraniTheme.primaryText)),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(subtitle,
                    style: GraniTheme.bodySmall.copyWith(
                        fontSize: 12.5,
                        height: 1.3,
                        color: const Color(0xFF5E6D79)))
              ],
            ]));
    Widget card(List<Widget> rows) => GraniSectionCard(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
        child: Material(
            color: Colors.transparent,
            child: Column(children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0)
                  const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 14),
                      child:
                          Divider(height: 1, color: GraniTheme.surfaceVariant)),
                rows[i]
              ]
            ])));
    final linked = deviceCount == null
        ? copy('Загружаем список…', 'Loading devices…')
        : copy('Привязано $deviceCount из $deviceLimit',
            '$deviceCount of $deviceLimit linked');

    final limitNotice = deviceCount != null && deviceCount! >= deviceLimit
        ? copy(
            deviceCount! > deviceLimit
                ? ' · Лимит превышен'
                : ' · Лимит достигнут',
            deviceCount! > deviceLimit
                ? ' · Over the limit'
                : ' · Limit reached')
        : '';

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      section(
          'profile-section-access',
          copy('Доступ', 'Access'),
          'assets/images/figma/profile/sub_icon.svg',
          GraniAccessCard(
              access: access,
              now: now,
              onPlan: onPlan,
              accountKey: avatarAccountKey)),
      const SizedBox(height: 22),
      section(
          'profile-section-gifts',
          copy('Подарки', 'Gifts'),
          'assets/images/figma/profile/share_new.svg',
          GraniGiftSection(
              onShare: onShare, onReceive: onReceive, onBonuses: onBonuses)),
      const SizedBox(height: 22),
      section(
          'profile-section-settings',
          copy('Настройки', 'Settings'),
          'assets/images/figma/profile/split_tunnel_new.svg',
          card([
            row(
                'profile-language',
                'assets/images/figma/profile/language_new.svg',
                copy('Язык', 'Language'),
                onLanguage,
                subtitle: language),
            if (showSplitTunnel)
              row(
                  'profile-split-tunnel',
                  'assets/images/figma/profile/split_tunnel_new.svg',
                  copy('Раздельный туннель', 'Split tunneling'),
                  onSplitTunnel,
                  subtitle: copy('Выбрать приложения', 'Choose apps')),
            row(
                'profile-devices',
                'assets/images/figma/profile/monitor_new.svg',
                copy('Устройства', 'Devices'),
                onDevices,
                subtitle: deviceError
                    ? copy('Не удалось обновить список',
                        'Could not refresh devices')
                    : linked + limitNotice),
            row(
                'profile-notifications',
                'assets/images/figma/profile/notifications_new.svg',
                copy('История уведомлений', 'Notification history'),
                onNotifications),
          ])),
      const SizedBox(height: 22),
      section(
          'profile-section-help',
          copy('Помощь', 'Help'),
          'assets/images/figma/profile/support_icon.svg',
          card([
            row('profile-support', 'assets/images/figma/profile/send_new.svg',
                copy('Написать в поддержку', 'Contact support'), onSupport,
                subtitle: copy('Telegram-чат', 'Telegram chat')),
          ])),
      const SizedBox(height: 22),
      section(
          'profile-section-account',
          copy('Аккаунт', 'Account'),
          'assets/images/figma/profile/account_icon.svg',
          card([
            row(
                'profile-copy-email',
                'assets/images/figma/profile/email_new.svg',
                copy('Почта', 'Email'),
                onCopyEmail,
                subtitle: email,
                semantics: copy('Скопировать почту', 'Copy email'),
                trailing: Icons.content_copy),
            row(
                'profile-copy-version',
                'assets/images/figma/profile/info_new.svg',
                copy('Версия приложения', 'App version'),
                onCopyVersion,
                subtitle: version,
                semantics: copy('Скопировать версию', 'Copy version'),
                trailing: Icons.content_copy),
          ])),
    ]);
  }
}

class GraniAccessCard extends StatelessWidget {
  const GraniAccessCard(
      {super.key,
      required this.access,
      required this.now,
      required this.onPlan,
      this.accountKey = ''});
  final ProfileAccessSnapshot access;
  final DateTime now;
  final String accountKey;
  final VoidCallback onPlan;

  @override
  Widget build(BuildContext context) {
    final ru = Localizations.localeOf(context).languageCode == 'ru';
    String copy(String russian, String english) => ru ? russian : english;
    final kind = access.kindAt(now);
    final title = switch (kind) {
      ProfileAccessKind.paid => copy('Оплаченный доступ', 'Paid access'),
      ProfileAccessKind.trial => copy('Пробный доступ', 'Trial access'),
      ProfileAccessKind.gift => copy('Подарочный доступ', 'Gift access'),
      ProfileAccessKind.bonus => copy('Бонусный доступ', 'Bonus access'),
      ProfileAccessKind.ended =>
        copy('Доступ не активен', 'Access is inactive'),
      ProfileAccessKind.unknown => copy('Статус уточняется', 'Checking access'),
    };
    final expiry = access.expiresAt(now);
    String date(DateTime time) =>
        DateFormat('d MMM y, HH:mm', ru ? 'ru' : 'en').format(time.toLocal());
    final valid = const {
      ProfileAccessKind.paid,
      ProfileAccessKind.trial,
      ProfileAccessKind.gift,
      ProfileAccessKind.bonus
    }.contains(kind);
    final expiryText = expiry == null
        ? valid
            ? copy('Срок уточняется при обновлении',
                'Expiry will update after refresh')
            : copy('Выберите тариф для доступа к VPN',
                'Choose a plan to use the VPN')
        : copy('До ${date(expiry)}', 'Until ${date(expiry)}');
    final payment = kind == ProfileAccessKind.paid
        ? access.source == 'google_play'
            ? 'Google Play'
            : access.source == 'wata_sbp'
                ? copy('СБП · WATA', 'SBP · WATA')
                : null
        : null;
    final waitingBonus =
        valid && access.bonusSeconds > 0 && kind != ProfileAccessKind.bonus;
    final bonusDays = access.bonusSeconds / 86400;
    final bonusAmount = bonusDays == bonusDays.roundToDouble()
        ? '${bonusDays.toInt()}'
        : bonusDays.toStringAsFixed(1);
    final paid = kind == ProfileAccessKind.paid;
    final accent = paid ? const Color(0xFF9C6200) : const Color(0xFF216781);
    final fraction = access.remainingFractionAt(now);
    final seconds = expiry == null
        ? 0
        : expiry.difference(now).inSeconds.clamp(0, 2147483647);
    final urgent = valid && expiry != null && seconds <= 6 * 3600;
    final barColor = urgent || (fraction != null && fraction < .1)
        ? const Color(0xFFCC3D36)
        : fraction != null && fraction < .25
            ? const Color(0xFFC97500)
            : accent;
    String remaining() {
      final days = seconds ~/ 86400;
      final hours = (seconds % 86400) ~/ 3600;
      final minutes = (seconds % 3600) ~/ 60;
      if (days > 0) {
        return copy(
            'Осталось: $days д. $hours ч.', 'Remaining: ${days}d ${hours}h');
      }
      if (hours > 0) {
        return copy('Осталось: $hours ч. $minutes мин.',
            'Remaining: ${hours}h ${minutes}m');
      }
      if (minutes > 0) {
        return copy('Осталось: $minutes мин.', 'Remaining: ${minutes}m');
      }
      return copy('Осталось меньше минуты', 'Less than a minute left');
    }

    return GraniSectionCard(
        key: const ValueKey('profile-access-card'),
        emphasized: valid,
        gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: paid
                ? const [Color(0xFFFFEAC3), Color(0xFFFFF7E9)]
                : valid
                    ? const [Color(0xFFE0F0FA), Color(0xFFF1F9FD)]
                    : const [Color(0xFFF0F3F5), Color(0xFFF7F9FA)]),
        borderColor: paid ? const Color(0xFFE3BC74) : const Color(0xFFB9D3E1),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            GraniAccessAvatar(
                key: const ValueKey('profile-access-avatar'),
                access: access,
                kind: kind,
                accountKey: accountKey),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(copy('ВАШ СТАТУС', 'YOUR STATUS'),
                      style: GraniTheme.bodySmall.copyWith(
                          fontSize: 10,
                          height: 1.3,
                          letterSpacing: 1.1,
                          fontWeight: FontWeight.w700,
                          color: accent)),
                  const SizedBox(height: 4),
                  Text(title,
                      key: const ValueKey('profile-access-title'),
                      style: GraniTheme.bodyMedium.copyWith(
                          fontSize: 18,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                          color: GraniTheme.primaryText)),
                ])),
          ]),
          const SizedBox(height: 16),
          Text(expiryText,
              key: const ValueKey('profile-access-expiry'),
              style: GraniTheme.bodyMedium.copyWith(
                  fontSize: 14,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: urgent ? barColor : GraniTheme.primaryText)),
          if (paid && fraction != null) ...[
            const SizedBox(height: 10),
            ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                    key: const ValueKey('profile-access-progress'),
                    value: fraction,
                    minHeight: 6,
                    color: barColor,
                    backgroundColor: accent.withOpacity(.13),
                    semanticsLabel: copy(
                        'Оставшийся срок доступа', 'Remaining access period'),
                    semanticsValue: remaining())),
            const SizedBox(height: 7),
            Text(remaining(),
                style: GraniTheme.bodySmall.copyWith(
                    fontSize: 12,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    color: barColor)),
          ],
          if (kind == ProfileAccessKind.unknown) ...[
            const SizedBox(height: 6),
            Text(
                copy('Ожидаем актуальные данные аккаунта',
                    'Waiting for current account data'),
                style: GraniTheme.bodySmall),
          ],
          if (paid) ...[
            const SizedBox(height: 8),
            Text(
                [
                  if (payment != null) payment,
                  access.autoRenew
                      ? copy('Автопродление включено', 'Auto-renewal is on')
                      : copy('Без автопродления', 'No auto-renewal')
                ].join(' · '),
                style: GraniTheme.bodySmall
                    .copyWith(height: 1.3, color: const Color(0xFF5E6D79))),
          ],
          if (waitingBonus) ...[
            const SizedBox(height: 10),
            Text(
                copy('Бонусы: $bonusAmount дн. после текущего доступа',
                    'Bonus: $bonusAmount days after current access'),
                style: GraniTheme.bodySmall
                    .copyWith(height: 1.3, color: GraniTheme.primaryText)),
          ],
          const SizedBox(height: 14),
          FilledButton(
              key: const ValueKey('profile-access-plan'),
              onPressed: onPlan,
              style: FilledButton.styleFrom(
                  backgroundColor: GraniTheme.warmAccent,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 48),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14))),
              child: Text(
                  paid && access.autoRenew
                      ? copy('Управлять подпиской', 'Manage subscription')
                      : paid
                          ? copy('Продлить доступ', 'Extend access')
                          : copy('Выбрать тариф', 'Choose a plan'),
                  textAlign: TextAlign.center,
                  style: GraniTheme.bodyMedium.copyWith(
                      fontSize: 14,
                      height: 1.25,
                      color: Colors.white,
                      fontWeight: FontWeight.w700))),
        ]));
  }
}

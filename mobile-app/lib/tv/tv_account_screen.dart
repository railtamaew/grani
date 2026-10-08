import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/session/locale_controller.dart';
import '../services/auth_service.dart';
import '../services/native_vpn_service.dart';
import 'tv_ui.dart';
import '../widgets/profile/profile_ui_kit.dart';
import '../theme.dart';

class TvAccountScreen extends StatefulWidget {
  const TvAccountScreen({super.key});
  @override
  State<TvAccountScreen> createState() => _TvAccountScreenState();
}

class _TvAccountScreenState extends State<TvAccountScreen> {
  bool _busy = false;

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tvText(context, 'Выйти из аккаунта?', 'Sign out?')),
        content: Text(
          tvText(
            context,
            'VPN на этом телевизоре будет отключён.',
            'VPN on this TV will disconnect.',
          ),
        ),
        actions: [
          TvButton(
            label: tvText(context, 'Остаться', 'Stay'),
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
          ),
          TvButton(
            label: tvText(context, 'Выйти', 'Sign out'),
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await NativeVpnService.disconnect(reason: 'logout', source: 'tv_account');
      if (!mounted) return;
      await context.read<AuthService>().logout();
      if (mounted)
        Navigator.pushNamedAndRemoveUntil(context, '/', (_) => false);
    } catch (_) {
      if (mounted) {
        await showTvNotice(
          context,
          tvText(
            context,
            'Не удалось выйти. Попробуйте ещё раз.',
            'Could not sign out. Please try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final expires = auth.subscriptionExpiresAt?.toLocal();
    final date = expires == null
        ? null
        : '${expires.day.toString().padLeft(2, '0')}.${expires.month.toString().padLeft(2, '0')}.${expires.year}';
    return TvPage(
      title: tvText(context, 'Аккаунт', 'Account'),
      contentWidth: 520,
      child: ListView(
        children: [
          GraniSectionCard(
              emphasized: true,
              child: Column(children: [
                const CircleAvatar(
                    radius: 28,
                    backgroundColor: GraniTheme.surfaceInset,
                    child: Icon(Icons.person_outline_rounded,
                        size: 30, color: GraniTheme.primaryText)),
                const SizedBox(height: 12),
                Text(auth.user?.email ?? '',
                    style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: GraniTheme.primaryText)),
              ])),
          const SizedBox(height: 14),
          TvNotice(
            auth.hasActiveSubscription
                ? tvText(
                    context,
                    date == null ? 'Доступ активен' : 'Доступ до $date',
                    date == null ? 'Access is active' : 'Access until $date',
                  )
                : (auth.trialSecondsLeft ?? 0) > 0
                    ? tvText(
                        context,
                        'Пробный доступ активен',
                        'Trial access is active',
                      )
                    : tvText(
                        context,
                        'Для подключения нужен доступ',
                        'Access is required to connect',
                      ),
          ),
          const SizedBox(height: 24),
          TvProfileRow(
            label: tvText(context, 'Тарифы и продление', 'Plans and renewal'),
            autofocus: true,
            asset: 'sub_icon.svg',
            onPressed: _busy
                ? null
                : () => Navigator.pushNamed(context, '/subscription'),
          ),
          const SizedBox(height: 14),
          TvProfileRow(
            label: tvText(context, 'Мои устройства', 'My devices'),
            asset: 'monitor_new.svg',
            onPressed:
                _busy ? null : () => Navigator.pushNamed(context, '/devices'),
          ),
          const SizedBox(height: 14),
          TvProfileRow(
            label: tvText(context, 'Исключения приложений', 'App exclusions'),
            asset: 'split_tunnel_new.svg',
            onPressed: _busy
                ? null
                : () => Navigator.pushNamed(context, '/split-tunnel'),
          ),
          const SizedBox(height: 14),
          TvProfileRow(
            label: tvText(context, 'Язык: Русский', 'Language: English'),
            asset: 'language_new.svg',
            onPressed: _busy
                ? null
                : () => context.read<LocaleController>().setLocale(
                      Locale(
                        Localizations.localeOf(context).languageCode == 'ru'
                            ? 'en'
                            : 'ru',
                      ),
                    ),
          ),
          const SizedBox(height: 14),
          TvProfileRow(
            label: tvText(context, 'Конфиденциальность', 'Privacy'),
            asset: 'document_new.svg',
            onPressed:
                _busy ? null : () => Navigator.pushNamed(context, '/privacy'),
          ),
          const SizedBox(height: 14),
          TvProfileRow(
            label: tvText(context, 'Выйти из аккаунта', 'Sign out'),
            asset: 'exit_new.svg',
            onPressed: _busy ? null : _logout,
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 18),
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }
}

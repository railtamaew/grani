import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../config/app_config.dart';
import '../services/auth_service.dart';
import '../services/referral_service.dart';
import '../services/native_vpn_service.dart';
import '../services/vpn_service.dart';
import '../widgets/grani_top_icon_button.dart';
import 'device_limit_screen.dart' show DeviceLimitResult, showDeviceLimitModal;
import '../widgets/snackbar_utils.dart';
import 'trial_ended_screen.dart' show SubscriptionScreenMode;
import '../core/session/locale_controller.dart';
import '../widgets/bottom_sheets/language_selector_bottom_sheet.dart';
import '../l10n/l10n.dart';
import '../core/errors/error_handler.dart';

import '../models/profile_access_snapshot.dart';
import '../widgets/profile/grani_menu_sections.dart';

/// Показывает профиль пользователя как Drawer (панель слева).
/// Grouped access, gifts, settings, help and account actions.
void showProfileDrawer(BuildContext context) {
  showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withOpacity(0.34),
    transitionDuration: const Duration(milliseconds: 300),
    pageBuilder: (ctx, animation, secondaryAnimation) {
      return const _ProfileDrawerContent();
    },
    transitionBuilder: (ctx, animation, secondaryAnimation, child) {
      final curved =
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(-1, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      );
    },
  );
}

// Figma frame: 364×915, screen 412×917
const double _kDrawerWidth = 364.0;
const double _kScreenWidth = 412.0;

class _ProfileDrawerContent extends StatefulWidget {
  const _ProfileDrawerContent();
  @override
  State<_ProfileDrawerContent> createState() => _ProfileDrawerState();
}

class _ProfileDrawerState extends State<_ProfileDrawerContent> {
  Timer? _clock;
  List<Map<String, dynamic>> _devices = [];
  bool _devicesLoading = true;
  String? _devicesLoadError;
  Future<void>? _loadDevicesInFlight;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) {
        setState(() {}); // Update the local ribbon, never a network loop.
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDevices());
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    final inFlight = _loadDevicesInFlight;
    if (inFlight != null) {
      return inFlight;
    }
    final fut = () async {
      try {
        if (!mounted) return;
        final vpnService = context.read<VpnService>();
        final list = await vpnService.fetchDevicesWithAuth();
        if (!mounted) return;
        setState(() {
          _devices = list.whereType<Map<String, dynamic>>().toList();
          _devicesLoading = false;
          _devicesLoadError = null;
        });
      } catch (e) {
        if (mounted) {
          setState(() {
            _devicesLoadError = ErrorHandler().userMessageForConnectionError(e);
            _devicesLoading = false;
            // _devices не очищаем — при таймауте/ошибке показываем последний успешный список.
          });
        }
      }
    }();
    _loadDevicesInFlight = fut;
    try {
      await fut;
    } finally {
      if (identical(_loadDevicesInFlight, fut)) {
        _loadDevicesInFlight = null;
      }
    }
  }

  int get _maxDevices {
    final auth = context.read<AuthService>();
    return auth.maxDevices;
  }

  int get _linkedCount => _devices.length;
  bool get _limitExceeded => _linkedCount > _maxDevices;
  Future<void> _onDevicesTap() async {
    if (_limitExceeded) {
      final result = await showDeviceLimitModal(
        context,
        initialDevices: _devices,
        maxDevices: _maxDevices,
      );
      if (!mounted) return;
      if (result == DeviceLimitResult.loggedOutCurrentDevice) {
        Navigator.popUntil(context, (r) => r.isFirst);
      } else if (result == DeviceLimitResult.resolved) {
        await _loadDevices();
      }
    } else {
      final navigator = Navigator.of(context);
      navigator.pop();
      navigator.pushNamed('/devices');
    }
  }

  String _supportValue(String? value) {
    final v = value?.trim();
    return v == null || v.isEmpty ? '—' : v;
  }

  String _supportAccessLabel(BuildContext context, AuthService auth) {
    final l10n = context.l10n;
    final kind = auth.profileAccessSnapshot.kindAt(DateTime.now());
    final ru = Localizations.localeOf(context).languageCode == 'ru';
    if (kind == ProfileAccessKind.bonus)
      return ru ? 'Бонусный доступ активен' : 'Bonus access active';
    if (kind == ProfileAccessKind.gift)
      return ru ? 'Подарочный доступ активен' : 'Gift access active';
    if (kind == ProfileAccessKind.paid) return l10n.profileSupportAccessPremium;
    if (kind == ProfileAccessKind.trial) return l10n.profileSupportAccessTrial;
    return l10n.profileSupportAccessLimited;
  }

  String _supportVpnStateLabel(BuildContext context, VpnService vpnService) {
    final l10n = context.l10n;
    if (vpnService.isConnected) return l10n.profileSupportVpnConnected;
    if (vpnService.isConnecting) return l10n.profileSupportVpnConnecting;
    if (vpnService.isDisconnecting) return l10n.profileSupportVpnDisconnecting;
    if (vpnService.lastError != null && vpnService.lastError!.isNotEmpty) {
      return l10n.profileSupportVpnError;
    }
    return l10n.profileSupportVpnDisconnected;
  }

  String _telegramStartPayload(AuthService auth) {
    final rawId = auth.user?.id.trim();
    if (rawId == null || rawId.isEmpty) return 'support_guest';
    final safeId = rawId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final payload = 'support_$safeId';
    return payload.length <= 64 ? payload : payload.substring(0, 64);
  }

  String _supportMessage(
    BuildContext context,
    AuthService auth,
    VpnService vpnService,
  ) {
    final l10n = context.l10n;
    final user = auth.user;
    final server = vpnService.selectedServer;
    final locale = Localizations.localeOf(context).languageCode;
    final serverLabel = server == null
        ? '—'
        : [
            server.id,
            server.city,
            server.country,
          ].where((part) => part.trim().isNotEmpty).join(' / ');
    return l10n.profileSupportPreparedMessage(
      _supportValue(user?.id),
      _supportValue(user?.email),
      AppConfig.appVersion,
      AppConfig.buildNumber,
      locale,
      _supportAccessLabel(context, auth),
      _supportVpnStateLabel(context, vpnService),
      _supportValue(serverLabel),
      vpnService.selectedProtocol.name,
      Platform.operatingSystem,
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  Future<void> _openTelegram(BuildContext context) async {
    final auth = context.read<AuthService>();
    final vpnService = context.read<VpnService>();
    final startPayload = _telegramStartPayload(auth);
    final deepLink = AppConfig.supportTelegramDeepLink(start: startPayload);
    final webLink = AppConfig.supportTelegramWebLink(start: startPayload);
    try {
      final message = _supportMessage(context, auth, vpnService);
      await Clipboard.setData(ClipboardData(text: message));
      if (context.mounted) {
        showInfoSnackBar(
          context,
          context.l10n.profileSupportInfoCopied,
          duration: const Duration(seconds: 2),
        );
      }
      var opened = false;
      try {
        opened =
            await launchUrl(deepLink, mode: LaunchMode.externalApplication);
      } catch (_) {
        // Telegram may be absent; continue with its public web URL.
      }
      if (!opened) {
        opened = await launchUrl(webLink, mode: LaunchMode.externalApplication);
      }
      if (!opened) throw StateError('Support link unavailable');
    } catch (_) {
      if (context.mounted) {
        showErrorSnackBar(context, context.l10n.profileOpenTelegramFailed);
      }
    }
  }

  void _navigate(String route, {Object? arguments}) {
    final navigator = Navigator.of(context);
    navigator.pop();
    navigator.pushNamed(route, arguments: arguments);
  }

  void _openPlan(AuthService auth) {
    final kind = auth.profileAccessSnapshot.kindAt(DateTime.now());
    final mode = kind == ProfileAccessKind.paid
        ? SubscriptionScreenMode.manage
        : kind == ProfileAccessKind.ended
            ? SubscriptionScreenMode.expired
            : SubscriptionScreenMode.upgrade;
    _navigate('/subscription', arguments: mode);
  }

  void _copyEmail(String email) {
    if (email.isEmpty || email == '—') return;
    Clipboard.setData(ClipboardData(text: email));
    showInfoSnackBar(context, context.l10n.profileEmailCopied);
  }

  void _copyVersion() {
    Clipboard.setData(ClipboardData(
        text: 'GRANI v${AppConfig.appVersion} (${AppConfig.buildNumber})'));
    showInfoSnackBar(context, context.l10n.profileVersionCopied);
  }

  @override
  Widget build(BuildContext context) {
    final width =
        MediaQuery.sizeOf(context).width * (_kDrawerWidth / _kScreenWidth);
    return Align(
        alignment: Alignment.centerLeft,
        child: GestureDetector(
            onHorizontalDragUpdate: (details) {
              if ((details.primaryDelta ?? 0) < -12) Navigator.pop(context);
            },
            child: Material(
                color: Colors.transparent,
                child: Container(
                  width: width,
                  height: double.infinity,
                  decoration: const BoxDecoration(
                      gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xFFFFFFFF), Color(0xFFF7F9FA)]),
                      borderRadius: BorderRadius.only(
                          topRight: Radius.circular(22),
                          bottomRight: Radius.circular(22))),
                  child: SafeArea(
                      child: Consumer<AuthService>(builder: (context, auth, _) {
                    final locale =
                        context.watch<LocaleController>().locale.languageCode;
                    final email = auth.user?.email ?? '—';
                    return SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const SizedBox(height: 8),
                              _buildTopBar(context),
                              const SizedBox(height: 18),
                              GraniMenuSections(
                                  access: auth.profileAccessSnapshot,
                                  avatarAccountKey: auth.token == null
                                      ? 'signed_out'
                                      : ReferralService.instance
                                          .presentationAccount(auth.token!),
                                  now: DateTime.now(),
                                  email: email,
                                  version:
                                      '${AppConfig.buildNumber} (${AppConfig.appVersion})',
                                  language: locale == 'ru'
                                      ? context.l10n.appLanguageRussian
                                      : context.l10n.appLanguageEnglish,
                                  deviceCount:
                                      _devicesLoading ? null : _devices.length,
                                  deviceLimit: auth.maxDevices,
                                  deviceError: _devicesLoadError != null,
                                  showSplitTunnel:
                                      Platform.isAndroid || Platform.isWindows,
                                  onPlan: () => _openPlan(auth),
                                  onShare: () => _navigate('/referrals'),
                                  onReceive: () => _navigate('/gift/receive'),
                                  onBonuses: () => _navigate('/gift/bonuses'),
                                  onLanguage: () =>
                                      LanguageSelectorBottomSheet.show(context),
                                  onSplitTunnel: () =>
                                      _navigate('/split-tunnel'),
                                  onDevices: _onDevicesTap,
                                  onNotifications: () =>
                                      _navigate('/notification-journal'),
                                  onSupport: () => _openTelegram(context),
                                  onCopyEmail: () => _copyEmail(email),
                                  onCopyVersion: _copyVersion),
                              const SizedBox(height: 16),
                              _buildLogoutButton(context),
                              const SizedBox(height: 24),
                            ]));
                  })),
                ))));
  }

  /// Menu (hamburger) + Logo lc (по центру)
  Widget _buildTopBar(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        GraniTopIconButton(
          assetName: 'assets/images/figma/profile/menu_new.svg',
          onTap: () => Navigator.pop(context),
          width: 48,
          height: 48,
          iconWidth: 26,
          iconHeight: 20,
          surfaceSize: 36,
          semanticLabel: context.l10n.profileClose,
          fallbackIcon: Icons.menu,
        ),
        const Spacer(),
        Text(
          context.l10n.profileTitle,
          style: GraniTheme.bodyMedium.copyWith(
            fontSize: 19,
            fontWeight: FontWeight.w800,
            color: GraniTheme.primaryText,
          ),
        ),
        const Spacer(),
        const SizedBox(width: 48), // балансировка для центрирования лого
      ],
    );
  }

  Widget _buildLogoutButton(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(top: GraniTheme.standardSectionPadding),
      child: Semantics(
        label: l10n.profileLogoutSemantic,
        button: true,
        child: SizedBox(
          width: double.infinity,
          child: Container(
            decoration: BoxDecoration(
              gradient: GraniTheme.surfaceControlGradient,
              borderRadius: BorderRadius.circular(GraniTheme.profileCardRadius),
              border: Border.all(
                color: GraniTheme.destructiveRed.withOpacity(0.46),
                width: 1,
              ),
              boxShadow: GraniTheme.surfaceControlShadowStrong,
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _confirmLogout(context),
                borderRadius:
                    BorderRadius.circular(GraniTheme.profileCardRadius),
                splashColor: GraniTheme.destructiveRed.withOpacity(0.08),
                highlightColor: GraniTheme.destructiveRed.withOpacity(0.04),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SvgPicture.asset(
                        'assets/images/figma/profile/exit_new.svg',
                        width: 18,
                        height: 18,
                        fit: BoxFit.contain,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        l10n.profileLogoutButton,
                        style: GraniTheme.bodyMedium.copyWith(
                          color: GraniTheme.destructiveRed,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GraniTheme.cardBackground,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          l10n.profileLogoutDialogTitle,
          style: GraniTheme.bodyMedium.copyWith(
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          l10n.profileLogoutDialogBody,
          style: GraniTheme.bodyMedium.copyWith(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              l10n.profileLogoutDialogCancel,
              style: GraniTheme.bodyMedium
                  .copyWith(color: GraniTheme.secondaryText),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.profileLogoutDialogConfirm,
              style: GraniTheme.bodyMedium.copyWith(
                color: GraniTheme.destructiveRed,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    var disconnectError = false;
    try {
      final vpnService = context.read<VpnService>();
      final amneziaWgConnected = await NativeVpnService.getAmneziaWgStatus()
          .timeout(const Duration(seconds: 1), onTimeout: () => null);
      if (amneziaWgConnected == true) {
        final stopped = await NativeVpnService.disconnectAmneziaWg(
          reason: 'logout',
          source: 'profile_logout',
        ).timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            disconnectError = true;
            return false;
          },
        );
        if (!stopped) disconnectError = true;
      }
      if (vpnService.isVpnSessionPotentiallyActive) {
        await vpnService.disconnect(source: 'profile_logout').timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            disconnectError = true;
            return false;
          },
        );
      }
    } catch (_) {
      disconnectError = true;
    }
    if (!context.mounted) return;
    await context.read<AuthService>().logout();
    if (!context.mounted) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    navigator.pop();
    navigator.pushNamedAndRemoveUntil('/', (_) => false);
    if (disconnectError) {
      showErrorSnackBarWithMessenger(
        messenger,
        l10n.profileLogoutDisconnectWarning,
      );
    }
  }
}

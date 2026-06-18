import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import '../theme.dart';
import '../config/app_config.dart';
import '../services/auth_service.dart';
import '../services/connection_logger.dart';
import '../services/native_vpn_service.dart';
import '../services/vpn_service.dart';
import '../models/vpn_protocol.dart';
import '../widgets/grani_top_icon_button.dart';
import 'device_limit_screen.dart' show DeviceLimitResult, showDeviceLimitModal;
import '../widgets/snackbar_utils.dart';
import '../widgets/profile/profile_ui_kit.dart';
import 'trial_ended_screen.dart' show SubscriptionScreenMode;
import '../core/session/locale_controller.dart';
import '../core/storage/storage_service.dart';
import '../widgets/bottom_sheets/language_selector_bottom_sheet.dart';
import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../l10n/subscription_plan_display.dart';
import '../core/errors/error_handler.dart';

/// Показывает профиль пользователя как Drawer (панель слева).
/// Figma: 1040-107 (Premium), 1117-296 (Trial).
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

class _ProfileDrawerContent extends StatelessWidget {
  const _ProfileDrawerContent();

  String? _premiumExpirationDate(AuthService auth) {
    if (!auth.hasActiveSubscription) return null;
    final expires = auth.subscriptionExpiresAt;
    if (expires == null) return null;
    return '${expires.day.toString().padLeft(2, '0')}.${expires.month.toString().padLeft(2, '0')}.${expires.year}';
  }

  String _premiumStatusLabel(BuildContext context, AuthService auth) {
    final l10n = context.l10n;
    final expires = auth.subscriptionExpiresAt;
    if (expires != null) {
      final d =
          '${expires.day.toString().padLeft(2, '0')}.${expires.month.toString().padLeft(2, '0')}.${expires.year}';
      return l10n.profileSubscriptionActiveUntil(d);
    }
    return l10n.profileSubscriptionActive;
  }

  String _trialExpirationLabel(AuthService auth) {
    final sec = auth.trialSecondsLeft ?? 0;
    if (sec <= 0) return '—';
    final end = DateTime.now().add(Duration(seconds: sec));
    return '${end.day.toString().padLeft(2, '0')}.${end.month.toString().padLeft(2, '0')}.${end.year}';
  }

  String _supportValue(String? value) {
    final v = value?.trim();
    return v == null || v.isEmpty ? '—' : v;
  }

  String _supportAccessLabel(BuildContext context, AuthService auth) {
    final l10n = context.l10n;
    if (auth.hasActiveSubscription) return l10n.profileSupportAccessPremium;
    if ((auth.trialSecondsLeft ?? 0) > 0) {
      return l10n.profileSupportAccessTrial;
    }
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
      try {
        await launchUrl(deepLink, mode: LaunchMode.externalApplication);
        return;
      } catch (_) {
        await launchUrl(webLink, mode: LaunchMode.externalApplication);
        return;
      }
    } catch (_) {
      if (context.mounted) {
        showErrorSnackBar(context, context.l10n.profileOpenTelegramFailed);
      }
    }
  }

  Future<void> _sendDiagnostics(BuildContext context) async {
    final auth = context.read<AuthService>();
    final vpnService = context.read<VpnService>();
    final token = auth.token;
    final user = auth.user;
    final locale = Localizations.localeOf(context).languageCode;
    final accessStatus = _supportAccessLabel(context, auth);
    final vpnState = _supportVpnStateLabel(context, vpnService);
    final server = vpnService.selectedServer;
    final serverLabel = server == null
        ? '—'
        : [
            server.id,
            server.city,
            server.country,
          ].where((part) => part.trim().isNotEmpty).join(' / ');

    try {
      final storage = StorageService();
      final storedDeviceId = await storage.getSecureString('device_id') ??
          await storage.getString('device_id');
      final deviceId = vpnService.deviceId ?? storedDeviceId;

      if (token == null ||
          token.isEmpty ||
          deviceId == null ||
          deviceId.isEmpty) {
        if (context.mounted) {
          showErrorSnackBar(context, context.l10n.profileDiagnosticsFailed);
        }
        return;
      }

      final protocol = vpnService.selectedProtocol.name;
      ConnectionLogger().setCredentials(
        token,
        deviceId,
        flushImmediately: false,
      );
      await ConnectionLogger().sendSupportDiagnosticReport(
        deviceId: deviceId,
        protocol: protocol,
        serverId: int.tryParse(server?.id ?? ''),
        details: <String, dynamic>{
          'report_id':
              'support_${DateTime.now().toUtc().millisecondsSinceEpoch}',
          'time_utc': DateTime.now().toUtc().toIso8601String(),
          'user_id': user?.id,
          'email': user?.email,
          'app_version': AppConfig.appVersion,
          'build_number': AppConfig.buildNumber,
          'language': locale,
          'access_status': accessStatus,
          'trial_seconds_left': auth.trialSecondsLeft,
          'subscription_expires_at':
              auth.subscriptionExpiresAt?.toIso8601String(),
          'vpn_state': vpnState,
          'vpn_connected': vpnService.isConnected,
          'vpn_connecting': vpnService.isConnecting,
          'vpn_disconnecting': vpnService.isDisconnecting,
          'last_error': vpnService.lastError,
          'server': serverLabel,
          'server_id': server?.id,
          'protocol': protocol,
          'platform': Platform.operatingSystem,
          'source': 'profile_support_card',
        },
      );

      if (context.mounted) {
        showInfoSnackBar(
          context,
          context.l10n.profileDiagnosticsSent,
          duration: const Duration(seconds: 2),
        );
      }
    } catch (_) {
      if (context.mounted) {
        showErrorSnackBar(context, context.l10n.profileDiagnosticsFailed);
      }
    }
  }

  Future<void> _shareApp(BuildContext context) async {
    try {
      await Share.share(
        context.l10n.profileSharePlayStoreMessage(AppConfig.sharePlayStoreUrl),
      );
    } catch (_) {
      if (context.mounted) {
        showErrorSnackBar(context, context.l10n.profileShareFailed);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    const ratio = _kDrawerWidth / _kScreenWidth;
    final drawerWidth = screenWidth * ratio;

    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        onHorizontalDragUpdate: (details) {
          if (details.primaryDelta != null && details.primaryDelta! < -12) {
            Navigator.pop(context);
          }
        },
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: drawerWidth,
            height: double.infinity,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFFFFFFF), Color(0xFFF7F9FA)],
              ),
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(22),
                bottomRight: Radius.circular(22),
              ),
              border: Border(
                right: BorderSide(
                  color: Colors.white.withOpacity(0.82),
                  width: 1,
                ),
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF06142E).withOpacity(0.11),
                  offset: const Offset(16, 0),
                  blurRadius: 44,
                  spreadRadius: -24,
                ),
              ],
            ),
            child: SafeArea(
              child: Consumer<AuthService>(
                builder: (context, auth, _) {
                  final isPremium = auth.hasActiveSubscription;
                  final isTrial = (auth.trialSecondsLeft ?? 0) > 0;
                  final email = auth.user?.email ?? '—';

                  return SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 8),
                        _buildTopBar(context),
                        const SizedBox(height: 18),
                        _buildProfileHeader(
                            context, isPremium, isTrial, email, auth),
                        const SizedBox(height: 22),
                        _buildSubscriptionSection(
                            context, isPremium, isTrial, auth),
                        const SizedBox(height: 20),
                        _AccountCard(email: email),
                        const SizedBox(height: 20),
                        _buildSupportSection(context),
                        const SizedBox(height: 20),
                        _buildAboutSection(context),
                        const SizedBox(height: 16),
                        _buildLogoutButton(context),
                        const SizedBox(height: 24),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAvatar(String email) {
    final initial =
        email.isNotEmpty && email != '—' ? email[0].toUpperCase() : 'G';
    return Container(
      width: 66,
      height: 66,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFFFFF), Color(0xFFEFF4F8)],
        ),
        border: Border.all(color: Colors.white.withOpacity(0.92), width: 1),
        boxShadow: GraniTheme.surfaceSoftShadow,
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: GraniTheme.bodyMedium.copyWith(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          color: GraniTheme.primaryText,
        ),
      ),
    );
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

  /// Аватар G слева + email/badge/status справа. Figma: Avatar 65×65 at (23, 114.5), account block at (110, 101)
  Widget _buildProfileHeader(
    BuildContext context,
    bool isPremium,
    bool isTrial,
    String email,
    AuthService auth,
  ) {
    final statusColor = isPremium
        ? GraniTheme.statusGreen
        : isTrial
            ? GraniTheme.statusBlue
            : GraniTheme.destructiveRed;
    final statusText = isPremium
        ? _premiumStatusLabel(context, auth)
        : isTrial
            ? context.l10n.profileTrialUntil(_trialExpirationLabel(auth))
            : context.l10n.profileAccessLimited;
    final badgeText = isPremium
        ? 'Premium'
        : (isTrial ? 'Trial' : context.l10n.profileNoSubscription);
    final badgeTextColor = isPremium
        ? GraniTheme.primaryText
        : isTrial
            ? GraniTheme.white
            : GraniTheme.primaryText;

    return GraniSectionCard(
      emphasized: true,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 15),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildAvatar(email),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  email,
                  style: GraniTheme.bodyMedium.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: GraniTheme.primaryText,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
                const SizedBox(height: 12),
                _buildBadge(isPremium, isTrial, badgeText, badgeTextColor),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        statusText,
                        style: GraniTheme.bodyMedium.copyWith(
                          color: GraniTheme.primaryText,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBadge(
      bool isPremium, bool isTrial, String text, Color textColor) {
    if (isPremium) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment(-0.8, -0.5),
            end: Alignment(0.8, 0.5),
            colors: [Color(0xFFFEF4C4), Color(0xFFFED150)],
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SvgPicture.asset(
              'assets/images/figma/profile/crown_new.svg',
              width: 20,
              height: 18,
              fit: BoxFit.contain,
            ),
            const SizedBox(width: 9),
            Text(
              text,
              style: GraniTheme.bodyMedium.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: textColor,
              ),
            ),
          ],
        ),
      );
    }

    final bgColor =
        isTrial ? GraniTheme.trialBadgeColor : const Color(0xFFE5E7EB);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isTrial)
            SvgPicture.asset(
              'assets/images/figma/profile/trial_icon.svg',
              width: 20,
              height: 20,
              fit: BoxFit.contain,
            ),
          if (isTrial) const SizedBox(width: 4),
          Text(
            text,
            style: GraniTheme.bodyMedium.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }

  double? _subscriptionProgress(AuthService auth) {
    final started = auth.subscriptionStartedAt;
    final expires = auth.subscriptionExpiresAt;
    if (started == null || expires == null) return null;
    final total = expires.difference(started).inSeconds;
    if (total <= 0) return 1.0;
    final elapsed = DateTime.now().difference(started).inSeconds;
    return (elapsed / total).clamp(0.0, 1.0);
  }

  Widget _buildSubscriptionSection(
    BuildContext context,
    bool isPremium,
    bool isTrial,
    AuthService auth,
  ) {
    final SubscriptionScreenMode mode;
    if (isPremium) {
      mode = SubscriptionScreenMode.manage;
    } else if (isTrial) {
      mode = SubscriptionScreenMode.upgrade;
    } else {
      mode = SubscriptionScreenMode.expired;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _SubscriptionCard(
          isPremium: isPremium,
          isTrial: isTrial,
          auth: auth,
          premiumExpirationDate: _premiumExpirationDate(auth),
          trialExpirationLabel: _trialExpirationLabel(auth),
          planName: auth.subscriptionPlanName,
          subscriptionProgress: _subscriptionProgress(auth),
          onTap: () {
            Navigator.pop(context);
            Navigator.pushNamed(context, '/subscription', arguments: mode);
          },
        ),
        if (isPremium) ...[
          const SizedBox(height: 10),
          _buildManageSubscriptionLink(context),
        ],
      ],
    );
  }

  Widget _buildManageSubscriptionLink(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        final uri = Uri.parse(
          'https://play.google.com/store/account/subscriptions?package=com.granivpn.mobile',
        );
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {
          if (context.mounted) {
            showErrorSnackBar(
                context, context.l10n.profileGooglePlayOpenFailed);
          }
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            const Icon(
              Icons.open_in_new,
              size: 14,
              color: GraniTheme.secondaryText,
            ),
            const SizedBox(width: 6),
            Text(
              context.l10n.profileGooglePlayManage,
              style: GraniTheme.bodyMedium.copyWith(
                fontSize: 12,
                color: GraniTheme.secondaryText,
                decoration: TextDecoration.underline,
                decorationColor: GraniTheme.secondaryText,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSupportSection(BuildContext context) {
    return _SupportCard(
      onShareTap: () => _shareApp(context),
      onSupportTap: () => _openTelegram(context),
      onDiagnosticsTap: () => _sendDiagnostics(context),
    );
  }

  Widget _buildAboutSection(BuildContext context) {
    return const _AboutCard();
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

/// Блок "Подписка" — Premium / Trial / Нет подписки.
class _SubscriptionCard extends StatelessWidget {
  final bool isPremium;
  final bool isTrial;
  final AuthService auth;
  final String? premiumExpirationDate;
  final String trialExpirationLabel;
  final String? planName;
  final double? subscriptionProgress;
  final VoidCallback onTap;

  const _SubscriptionCard({
    required this.isPremium,
    required this.isTrial,
    required this.auth,
    this.premiumExpirationDate,
    required this.trialExpirationLabel,
    this.planName,
    this.subscriptionProgress,
    required this.onTap,
  });

  static const int _trialTotalSeconds = 24 * 60 * 60;

  Color _trialDateColor(int secondsLeft) {
    if (secondsLeft > 24 * 3600) return GraniTheme.primaryText;
    if (secondsLeft > 6 * 3600) return GraniTheme.warningOrange;
    return GraniTheme.destructiveRed;
  }

  Color _trialProgressColor(int secondsLeft) {
    final remaining = secondsLeft / _trialTotalSeconds;
    if (remaining >= 0.5) return GraniTheme.statusBlue;
    if (remaining >= 0.2) return GraniTheme.warningOrange;
    return GraniTheme.destructiveRed;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GraniSectionHeader(
          iconSvg: 'assets/images/figma/profile/sub_icon.svg',
          title: l10n.profileSubscriptionSection,
        ),
        const SizedBox(height: 12),
        GraniSectionCard(
          emphasized: true,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          onTap: onTap,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _buildCardContent(context, l10n)),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: SvgPicture.asset(
                  'assets/images/figma/profile/version_new.svg',
                  width: 10,
                  height: 14,
                  fit: BoxFit.contain,
                  colorFilter: const ColorFilter.mode(
                      GraniTheme.secondaryText, BlendMode.srcIn),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCardContent(BuildContext context, AppLocalizations l10n) {
    if (isPremium) return _buildPremiumContent(l10n);
    if (isTrial) return _buildTrialContent(l10n);
    return _buildNoSubscriptionContent(l10n);
  }

  Widget _buildPremiumContent(AppLocalizations l10n) {
    final hasDate = premiumExpirationDate != null;
    final displayPlan = localizedSubscriptionPlanDisplay(l10n, planName);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _subscriptionRow(
          iconSvg: 'assets/images/figma/profile/document_new.svg',
          label: l10n.profileSubscriptionPlan,
          value: displayPlan,
          valueBold: true,
        ),
        if (hasDate) ...[
          const SizedBox(height: 10),
          _subscriptionRow(
            iconSvg: 'assets/images/figma/profile/calendar_new.svg',
            label: l10n.profileNextPayment,
            value: premiumExpirationDate!,
            valueColor: const Color(0xFF039E1C),
            valueBold: true,
            small: true,
          ),
          const SizedBox(height: 8),
          _buildPaymentProgressLine(),
        ],
      ],
    );
  }

  Widget _buildTrialContent(AppLocalizations l10n) {
    final sec = auth.trialSecondsLeft ?? 0;
    final progress =
        sec <= 0 ? 1.0 : (1.0 - (sec / _trialTotalSeconds)).clamp(0.0, 1.0);
    final dateColor = _trialDateColor(sec);
    final progressColor = _trialProgressColor(sec);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _subscriptionRow(
          iconSvg: 'assets/images/figma/profile/document_new.svg',
          label: l10n.profileSubscriptionPlan,
          value: l10n.profileTrialAccess,
          valueBold: true,
        ),
        const SizedBox(height: 10),
        _subscriptionRow(
          iconSvg: 'assets/images/figma/profile/calendar_new.svg',
          label: l10n.profileTrialEnds,
          value: trialExpirationLabel,
          valueColor: dateColor,
          valueBold: true,
          small: true,
        ),
        const SizedBox(height: 8),
        _buildProgressLine(progress, progressColor),
      ],
    );
  }

  Widget _buildNoSubscriptionContent(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _subscriptionRow(
          iconSvg: 'assets/images/figma/profile/document_new.svg',
          label: l10n.profileSubscriptionPlan,
          value: l10n.profileNoPlan,
          valueBold: true,
        ),
        const SizedBox(height: 10),
        Text(
          l10n.profileChoosePlanContinue,
          style: GraniTheme.bodySmall.copyWith(color: GraniTheme.secondaryText),
        ),
      ],
    );
  }

  Widget _subscriptionRow({
    required String iconSvg,
    required String label,
    required String value,
    Color? valueColor,
    bool valueBold = false,
    bool small = false,
  }) {
    final fontSize = small ? 14.0 : 16.0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SvgPicture.asset(
          iconSvg,
          width: 20,
          height: 20,
          fit: BoxFit.contain,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: GraniTheme.bodyMedium.copyWith(
                color: GraniTheme.primaryText,
                fontSize: fontSize,
                fontWeight: FontWeight.w500,
              ),
              children: [
                TextSpan(text: '$label '),
                TextSpan(
                  text: value,
                  style: TextStyle(
                    fontWeight: valueBold ? FontWeight.w700 : FontWeight.w400,
                    color: valueColor ?? GraniTheme.primaryText,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPaymentProgressLine() {
    final factor = (subscriptionProgress ?? 0.0).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(left: 30, bottom: 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: SizedBox(
          height: 3,
          child: Stack(
            children: [
              Container(color: GraniTheme.surfaceVariant),
              FractionallySizedBox(
                widthFactor: factor,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF039E1C),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProgressLine(double progress, Color fillColor) {
    final p = progress.clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(left: 30, bottom: 4),
      child: LayoutBuilder(
        builder: (_, constraints) {
          final fillWidth = constraints.maxWidth * p;
          return ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              height: 3,
              child: Stack(
                children: [
                  Container(
                    width: constraints.maxWidth,
                    color: GraniTheme.surfaceVariant,
                  ),
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      width: fillWidth,
                      decoration: BoxDecoration(
                        color: fillColor,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Блок «Аккаунт» — Email + Устройства.
class _AccountCard extends StatefulWidget {
  final String email;

  const _AccountCard({required this.email});

  @override
  State<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends State<_AccountCard> {
  List<Map<String, dynamic>> _devices = [];
  bool _devicesLoading = true;
  String? _devicesLoadError;
  Future<void>? _loadDevicesInFlight;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDevices());
  }

  Future<void> _loadDevices() async {
    final inFlight = _loadDevicesInFlight;
    if (inFlight != null) {
      return inFlight;
    }
    final fut = () async {
      try {
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

  int get _connectedCount => _devices.length;
  bool get _limitExceeded => _connectedCount > _maxDevices;
  bool get _limitReached =>
      _connectedCount == _maxDevices && _connectedCount > 0;

  Color _statusColor() {
    if (_limitExceeded) return GraniTheme.dangerRed;
    if (_limitReached) return GraniTheme.warningOrange;
    return GraniTheme.successGreen;
  }

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

  void _copyEmail() {
    final email = widget.email;
    if (email.isEmpty || email == '—') return;
    Clipboard.setData(ClipboardData(text: email));
    showInfoSnackBar(context, context.l10n.profileEmailCopied);
  }

  @override
  Widget build(BuildContext context) {
    final connected =
        _devicesLoading || _devicesLoadError != null ? 0 : _connectedCount;
    final limit = _maxDevices;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GraniSectionHeader(
          iconSvg: 'assets/images/figma/profile/account_icon.svg',
          title: context.l10n.profileAccount,
        ),
        const SizedBox(height: 12),
        GraniSectionCard(
          child: Column(
            children: [
              GraniSectionRow(
                iconSvg: 'assets/images/figma/profile/email_new.svg',
                label: 'Email',
                value: widget.email,
                onTap: _copyEmail,
                semanticLabel: context.l10n.profileCopyEmail,
                spacingAfterIcon: 14,
              ),
              const Divider(height: 1, color: GraniTheme.surfaceVariant),
              if (Platform.isAndroid) ...[
                GraniSectionRow(
                  iconSvg: 'assets/images/figma/profile/split_tunnel_new.svg',
                  label: context.l10n.splitTunnelTitle,
                  value: context.l10n.profileLanguageValue,
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.pushNamed(context, '/split-tunnel');
                  },
                  semanticLabel: context.l10n.profileSelectSplitTunnelApps,
                  spacingAfterIcon: 14,
                ),
                const Divider(height: 1, color: GraniTheme.surfaceVariant),
              ],
              GraniSectionRow(
                iconSvg: 'assets/images/figma/profile/monitor_new.svg',
                label: context.l10n.profileDevices,
                valueWidget: _devicesLoading
                    ? Text('—',
                        style: GraniTheme.bodyMedium
                            .copyWith(color: GraniTheme.secondaryText))
                    : _devicesLoadError != null
                        ? Text(
                            _devicesLoadError!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: GraniTheme.bodySmall.copyWith(
                              color: GraniTheme.warningOrange,
                              fontSize: 13,
                            ),
                          )
                        : RichText(
                            text: TextSpan(
                              style: GraniTheme.bodyMedium.copyWith(
                                color: GraniTheme.primaryText,
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                              children: [
                                TextSpan(
                                    text: context.l10n.profileDevicesFrom(
                                        '$connected', '$limit')),
                                TextSpan(
                                  text: context.l10n.profileDevicesConnected,
                                  style: TextStyle(
                                    color: _statusColor(),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                onTap: _onDevicesTap,
                semanticLabel: context.l10n.profileOpenDevices,
                spacingAfterIcon: 14,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Блок «Поддержка» — Поделиться GRANI + Поддержка (Telegram).
class _SupportCard extends StatelessWidget {
  final VoidCallback onShareTap;
  final VoidCallback onSupportTap;
  final VoidCallback onDiagnosticsTap;

  const _SupportCard({
    required this.onShareTap,
    required this.onSupportTap,
    required this.onDiagnosticsTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GraniSectionHeader(
          iconSvg: 'assets/images/figma/profile/support_icon.svg',
          title: context.l10n.profileSupport,
        ),
        const SizedBox(height: 12),
        GraniSectionCard(
          child: Column(
            children: [
              GraniSectionRow(
                iconSvg: 'assets/images/figma/profile/share_new.svg',
                labelWidget: Text.rich(
                  TextSpan(
                    style: GraniTheme.bodyMedium.copyWith(
                      color: GraniTheme.primaryText,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    children: [
                      TextSpan(text: '${context.l10n.profileSharePrefix} '),
                      TextSpan(
                        text: 'GRANI',
                        style: GraniTheme.bodyMedium.copyWith(
                          color: GraniTheme.primaryText,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                onTap: onShareTap,
                spacingAfterIcon: 10,
              ),
              const Divider(height: 1, color: GraniTheme.surfaceVariant),
              GraniSectionRow(
                iconSvg: 'assets/images/figma/profile/send_new.svg',
                labelWidget: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.profileSupportChat,
                      style: GraniTheme.bodyMedium.copyWith(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0,
                        color: GraniTheme.primaryText,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      context.l10n.profileSupportChatSubtitle,
                      style: GraniTheme.bodyMedium.copyWith(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                        color: GraniTheme.secondaryText,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
                onTap: onSupportTap,
                semanticLabel: context.l10n.profileSupportChatSemantic,
                spacingAfterIcon: 10,
              ),
              const Divider(height: 1, color: GraniTheme.surfaceVariant),
              GraniSectionRow(
                iconSvg: 'assets/images/figma/profile/info_new.svg',
                labelWidget: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.profileDiagnostics,
                      style: GraniTheme.bodyMedium.copyWith(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0,
                        color: GraniTheme.primaryText,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      context.l10n.profileDiagnosticsSubtitle,
                      style: GraniTheme.bodyMedium.copyWith(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                        color: GraniTheme.secondaryText,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
                onTap: onDiagnosticsTap,
                semanticLabel: context.l10n.profileDiagnosticsSemantic,
                spacingAfterIcon: 10,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Блок «О приложении» — Версия (копирование по тапу).
class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final localeController = context.watch<LocaleController>();
    final languageCode = localeController.locale.languageCode.toLowerCase();
    final currentLanguageLabel = languageCode == 'ru'
        ? l10n.appLanguageRussian
        : l10n.appLanguageEnglish;
    final versionStr = '${AppConfig.buildNumber} (${AppConfig.appVersion})';
    final hasVersion =
        AppConfig.appVersion.isNotEmpty || AppConfig.buildNumber.isNotEmpty;
    final copyText =
        'GRANI v${AppConfig.appVersion} (${AppConfig.buildNumber})';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GraniSectionHeader(
          iconSvg: 'assets/images/figma/profile/info_new.svg',
          title: l10n.profileAbout,
        ),
        const SizedBox(height: 12),
        GraniSectionCard(
          child: Column(
            children: [
              GraniSectionRow(
                iconSvg: 'assets/images/figma/profile/version_new.svg',
                label: l10n.profileVersion,
                value: hasVersion ? versionStr : '—',
                onTap: hasVersion
                    ? () {
                        Clipboard.setData(ClipboardData(text: copyText));
                        showInfoSnackBar(context, l10n.profileVersionCopied);
                      }
                    : null,
                semanticLabel: hasVersion ? l10n.profileCopyVersion : null,
                enabled: hasVersion,
                spacingAfterIcon: 10,
              ),
              const Divider(height: 1, color: GraniTheme.surfaceVariant),
              GraniSectionRow(
                iconSvg: 'assets/images/figma/profile/language_new.svg',
                label: l10n.profileLanguage,
                value: currentLanguageLabel,
                onTap: () => LanguageSelectorBottomSheet.show(context),
                spacingAfterIcon: 10,
              ),
              const Divider(height: 1, color: GraniTheme.surfaceVariant),
              GraniSectionRow(
                iconSvg: 'assets/images/figma/profile/notifications_new.svg',
                label: l10n.notificationJournalMenu,
                onTap: () {
                  Navigator.pop(context);
                  Navigator.pushNamed(context, '/notification-journal');
                },
                semanticLabel: l10n.notificationJournalMenu,
                spacingAfterIcon: 10,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

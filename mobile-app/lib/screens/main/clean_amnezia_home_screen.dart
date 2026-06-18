import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../config/app_config.dart';
import '../../simple_vpn/simple_vpn_api.dart';
import '../../simple_vpn/simple_vpn_controller.dart';
import '../../services/auth_service.dart';
import '../../services/native_vpn_service.dart';
import '../../services/vpn_service.dart';
import '../../theme.dart';
import '../../utils/flag_emoji.dart';
import '../../widgets/adaptive_text.dart';
import '../../widgets/button_connection.dart';
import '../../widgets/connection_block.dart';
import '../../widgets/snackbar_utils.dart';
import '../../widgets/ui_density.dart';
import '../../widgets/vpn_top_bar.dart';
import '../bottom_sheet_profile.dart';
import '../trial_ended_screen.dart' show SubscriptionScreenMode;
import '../../l10n/l10n.dart';
import 'vpn_shell_ui_helpers.dart';

/// Old Grani visual shell with the legacy VPN machinery removed.
/// The only active tunnel path is SimpleVpnController -> /simple-vpn -> AmneziaWG.
class CleanAmneziaHomeScreen extends StatefulWidget {
  const CleanAmneziaHomeScreen({super.key});

  @override
  State<CleanAmneziaHomeScreen> createState() => _CleanAmneziaHomeScreenState();
}

class _CleanAmneziaHomeScreenState extends State<CleanAmneziaHomeScreen>
    with WidgetsBindingObserver {
  late final SimpleVpnController _controller;
  bool _quickTileActionInFlight = false;
  bool _subscriptionRedirectScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final authService = context.read<AuthService>();
    final vpnService = context.read<VpnService>();
    _controller = SimpleVpnController(
      deviceIdProvider: () async => vpnService.deviceId,
      ensureDeviceRegistered: () async {
        final token = authService.token;
        if (token == null || token.isEmpty) return;
        await vpnService.ensureDeviceRegistered(token);
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.loadOptions();
      _controller.syncNativeState();
      _consumeQuickTileAction();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _controller.syncNativeState();
      _consumeQuickTileAction();
    }
  }

  void _scheduleSubscriptionRedirect() {
    if (_subscriptionRedirectScheduled) return;
    _subscriptionRedirectScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route?.settings.name == '/subscription') return;
      Navigator.of(context).pushNamed(
        '/subscription',
        arguments: SubscriptionScreenMode.expired,
      );
    });
  }

  Future<void> _consumeQuickTileAction() async {
    if (_quickTileActionInFlight) return;
    _quickTileActionInFlight = true;
    try {
      final action = await NativeVpnService.takeQuickTileAction();
      if (!mounted || action != 'toggle') return;
      await _controller.syncNativeState();
      if (!mounted) return;
      await _controller.toggle(source: 'quick_tile');
      try {
        await const MethodChannel('com.granivpn.mobile/vpn')
            .invokeMethod<void>('requestQuickTileRefresh');
      } catch (_) {}
    } finally {
      _quickTileActionInFlight = false;
    }
  }

  ButtonConnectionState _buttonState(SimpleVpnState state) {
    return switch (state) {
      SimpleVpnState.connected => ButtonConnectionState.on,
      SimpleVpnState.connecting => ButtonConnectionState.connecting,
      SimpleVpnState.disconnecting => ButtonConnectionState.disconnecting,
      SimpleVpnState.error => ButtonConnectionState.error,
      SimpleVpnState.disconnected => ButtonConnectionState.off,
    };
  }

  String _title(BuildContext context, ButtonConnectionState state) {
    final l10n = context.l10n;
    return switch (state) {
      ButtonConnectionState.connecting => l10n.homeConnecting,
      ButtonConnectionState.disconnecting => l10n.homeDisconnecting,
      ButtonConnectionState.on => l10n.homeProtectedTitle,
      ButtonConnectionState.error => l10n.homeConnectionFailedTitle,
      ButtonConnectionState.off => l10n.homeReadyTitle,
    };
  }

  String _subtitle(BuildContext context, ButtonConnectionState state) {
    final l10n = context.l10n;
    return switch (state) {
      ButtonConnectionState.on => l10n.homeProtectedSubtitle,
      ButtonConnectionState.connecting =>
        VpnShellUiHelpers.simpleProgressMessage(
          _controller.connectionProgressText,
          l10n,
        ),
      ButtonConnectionState.disconnecting =>
        _controller.connectionProgressText == null
            ? l10n.homeDisconnectingSubtitle
            : VpnShellUiHelpers.simpleProgressMessage(
                _controller.connectionProgressText,
                l10n,
              ),
      ButtonConnectionState.error => l10n.homeConnectionFailedSubtitle,
      ButtonConnectionState.off => l10n.homeReadySubtitle,
    };
  }

  String? _connectionContext(
      BuildContext context, ButtonConnectionState state) {
    if (state != ButtonConnectionState.connecting) return null;
    return VpnShellUiHelpers.simpleConnectionBadge(
      _controller.connectionModeBadge,
      context.l10n,
    );
  }

  Widget _buildConnectionStageTimeline(
    BuildContext context,
    ButtonConnectionState state,
    double scaleX,
    double scaleY,
  ) {
    final show = state == ButtonConnectionState.connecting ||
        state == ButtonConnectionState.disconnecting;
    final percent = _controller.connectionProgressPercent;
    final value = state == ButtonConnectionState.disconnecting
        ? null
        : (percent == null ? null : percent.clamp(0, 100) / 100.0);
    return Visibility(
      visible: show,
      maintainSize: true,
      maintainAnimation: true,
      maintainState: true,
      child: Padding(
        padding: EdgeInsets.only(top: 8 * scaleY),
        child: Column(
          children: [
            Semantics(
              label: context.l10n.connectionStagesProgressSemantic,
              child: SizedBox(
                width: 220 * scaleX,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: value,
                    minHeight: 4 * scaleY,
                    backgroundColor: GraniTheme.secondaryText.withOpacity(0.25),
                    color: const Color(0xFF192F3F),
                  ),
                ),
              ),
            ),
            SizedBox(height: 6 * scaleY),
            Text(
              context.l10n.connectionStagesTitle,
              style: TextStyle(
                fontFamily: 'Montserrat',
                fontWeight: FontWeight.w400,
                fontSize: 11 * scaleX,
                color: GraniTheme.secondaryText,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showLockedSelectorMessage() {
    showErrorSnackBar(context, context.l10n.homeSelectorLocked);
  }

  Future<void> _showServerSheet() async {
    if (_controller.isBusy || _controller.isConnected) {
      _showLockedSelectorMessage();
      return;
    }
    if (_controller.servers.isEmpty) {
      await _controller.loadOptions();
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (context) {
        final locale = Localizations.localeOf(context);
        final servers = _controller.servers;
        return _SelectorBottomSheet(
          title: context.l10n.serversTitle,
          child: servers.isEmpty
              ? _EmptySelectorState(context.l10n.serversNotLoaded)
              : ListView.separated(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: servers.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final server = servers[index];
                    return _ServerSheetRow(
                      server: server,
                      locale: locale,
                      selected: server.id == _controller.selectedServer?.id,
                      onTap: () {
                        _controller.selectServer(server);
                        Navigator.of(context).pop();
                      },
                    );
                  },
                ),
        );
      },
    );
  }

  Future<void> _showProtocolSheet() async {
    if (_controller.isBusy || _controller.isConnected) {
      _showLockedSelectorMessage();
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (context) {
        final protocols = _controller.protocols;
        return _SelectorBottomSheet(
          title: context.l10n.protocolSheetTitle,
          child: ListView.separated(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: protocols.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final protocol = protocols[index];
              return _ProtocolSheetRow(
                protocol: protocol,
                selected: protocol.id == _controller.selectedProtocol.id,
                onTap: () {
                  _controller.selectProtocol(protocol);
                  Navigator.of(context).pop();
                },
              );
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final screenWidth = mq.size.width;
    final screenHeight = mq.size.height;
    final safeBottom = mq.padding.bottom;
    const designWidth = 412.0;
    const designHeight = 917.0;
    final scaleX = screenWidth / designWidth;
    final scaleY = screenHeight / designHeight;
    final density = UiTokens.determineDensity(context);
    final tokens = UiTokens.of(density);
    final titleBlockWidth = 347 * scaleX;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        if (_controller.accessRequired) {
          _scheduleSubscriptionRedirect();
        } else {
          _subscriptionRedirectScheduled = false;
        }
        final state = _buttonState(_controller.state);
        final flowBadge = _connectionContext(context, state);
        final controlsDisabled = _controller.isBusy || _controller.isConnected;
        final titleBlockTopBase =
            (12 + 39 + 12 + GraniTheme.trialTitleBlockTopGap) * scaleY;
        final minTitleBlockTop = (12 + 39 + 28) * scaleY;
        final estimatedButtonGroupHeight = (330 * scaleX) +
            (18 + GraniTheme.selectorButtonHeight + 64) * scaleY;
        final buttonGroupTop = screenHeight -
            safeBottom -
            GraniTheme.vpnCardBottomMargin * scaleY -
            estimatedButtonGroupHeight;
        final titleBlockHeight = (flowBadge == null ? 88 : 110) * scaleY;
        final titleBlockTop = math.max(
          minTitleBlockTop,
          math.min(
            titleBlockTopBase,
            buttonGroupTop - titleBlockHeight - 18 * scaleY,
          ),
        );
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
            backgroundColor: Colors.transparent,
            resizeToAvoidBottomInset: false,
            body: Container(
              decoration: const BoxDecoration(
                gradient: GraniTheme.startScreenBackgroundGradient,
              ),
              child: SafeArea(
                bottom: false,
                child: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        height: safeBottom +
                            GraniTheme.navigationBarHeight * scaleY,
                        color: const Color(0xFFF7F9FA),
                      ),
                    ),
                    VpnTopBar(
                      scaleX: scaleX,
                      scaleY: scaleY,
                      onMenuTap: () => showProfileDrawer(context),
                      onShareTap: () async {
                        try {
                          await Share.share(
                            context.l10n.profileSharePlayStoreMessage(
                                AppConfig.sharePlayStoreUrl),
                          );
                        } catch (_) {
                          if (context.mounted) {
                            showErrorSnackBar(
                                context, context.l10n.profileShareFailed);
                          }
                        }
                      },
                    ),
                    Positioned(
                      top: titleBlockTop,
                      left: (screenWidth - titleBlockWidth) / 2,
                      child: SizedBox(
                        width: titleBlockWidth,
                        height: titleBlockHeight,
                        child: ClipRect(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            mainAxisSize: MainAxisSize.max,
                            children: [
                              AdaptiveTitleText(
                                text: _title(context, state),
                                maxLines: tokens.titleMaxLines,
                                minScale: tokens.titleMinScale,
                                style: TextStyle(
                                  fontFamily: 'Montserrat',
                                  fontWeight: FontWeight.w400,
                                  fontSize:
                                      GraniTheme.trialTitleFontSize * scaleX,
                                  height: 28.8 / GraniTheme.trialTitleFontSize,
                                  letterSpacing: 0,
                                  color: const Color(0xFF192F3F),
                                ),
                                textAlign: TextAlign.center,
                              ),
                              if (flowBadge != null) ...[
                                SizedBox(height: 7 * scaleY),
                                Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 10 * scaleX,
                                    vertical: 4 * scaleY,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.42),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: const Color(0xFFE6EBF2)
                                          .withOpacity(0.68),
                                      width: 1,
                                    ),
                                  ),
                                  child: Text(
                                    flowBadge,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontFamily: 'Montserrat',
                                      fontWeight: FontWeight.w500,
                                      fontSize: 12 * scaleX,
                                      height: 1.1,
                                      letterSpacing: 0,
                                      color: const Color(0xFF6F8194),
                                    ),
                                  ),
                                ),
                              ],
                              SizedBox(height: tokens.textGap * scaleY),
                              Flexible(
                                child: AdaptiveSubtitleText(
                                  text: _subtitle(context, state),
                                  maxLines:
                                      math.min(tokens.subtitleMaxLines, 2),
                                  style: TextStyle(
                                    fontFamily: 'Montserrat',
                                    fontWeight: FontWeight.w300,
                                    fontSize: 16 * scaleX,
                                    height: 15.52 / 16,
                                    letterSpacing: 0,
                                    color: const Color(0xFF192F3F),
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom:
                          GraniTheme.vpnCardBottomMargin * scaleY + safeBottom,
                      left: (screenWidth -
                              GraniTheme.backgroundBoxWidth * scaleX) /
                          2,
                      child: SizedBox(
                        width: GraniTheme.backgroundBoxWidth * scaleX,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ConnectionBlock(
                              scaleX: scaleX,
                              scaleY: scaleY,
                              showSpeedModule: false,
                              connectionState: state,
                              progressMessage:
                                  state == ButtonConnectionState.connecting
                                      ? context.l10n.btnVpnCancel
                                      : null,
                              errorMessage: _controller.error,
                              progressPercent:
                                  _controller.connectionProgressPercent,
                              showCancelHint: false,
                              onConnectionTap: _controller.isConnecting
                                  ? () => _controller.cancelConnect()
                                  : (_controller.isBusy
                                      ? null
                                      : _controller.toggle),
                            ),
                            _buildConnectionStageTimeline(
                              context,
                              state,
                              scaleX,
                              scaleY,
                            ),
                            SizedBox(height: 18 * scaleY),
                            Opacity(
                              opacity: controlsDisabled ? 0.74 : 1.0,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _SelectorChip(
                                    scaleX: scaleX,
                                    scaleY: scaleY,
                                    icon: Text(
                                      FlagEmoji.getFlagEmoji(_controller
                                              .selectedServer?.countryCode ??
                                          _controller.selectedServer?.country ??
                                          ''),
                                      style: TextStyle(fontSize: 14 * scaleX),
                                    ),
                                    label: _controller.optionsLoading
                                        ? 'Загрузка'
                                        : _localizedServerLabel(
                                            _controller.selectedServer,
                                            Localizations.localeOf(context)),
                                    onTap: _showServerSheet,
                                  ),
                                  SizedBox(
                                      width: GraniTheme.selectorButtonGap *
                                          scaleX),
                                  _SelectorChip(
                                    scaleX: scaleX,
                                    scaleY: scaleY,
                                    icon: Icon(
                                      _simpleProtocolIcon(
                                          _controller.selectedProtocol.id),
                                      size: GraniTheme.selectorButtonIconSize *
                                          scaleX *
                                          0.9,
                                      color:
                                          GraniTheme.selectorButtonIconProtocol,
                                    ),
                                    label: _protocolTitle(
                                        context,
                                        _controller.selectedProtocol.id,
                                        _controller.selectedProtocol.label),
                                    onTap: _showProtocolSheet,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SelectorChip extends StatelessWidget {
  const _SelectorChip({
    required this.scaleX,
    required this.scaleY,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final double scaleX;
  final double scaleY;
  final Widget icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius:
            BorderRadius.circular(GraniTheme.selectorButtonRadius * scaleX),
        splashColor: GraniTheme.primaryText.withOpacity(0.1),
        highlightColor: GraniTheme.primaryText.withOpacity(0.05),
        child: Container(
          width: GraniTheme.selectorButtonWidth * scaleX,
          height: GraniTheme.selectorButtonHeight * scaleY,
          padding: EdgeInsets.symmetric(
            horizontal: GraniTheme.selectorButtonPaddingH * scaleX,
            vertical: GraniTheme.selectorButtonPaddingV * scaleY,
          ),
          decoration: BoxDecoration(
            gradient: GraniTheme.surfaceControlGradient,
            borderRadius:
                BorderRadius.circular(GraniTheme.selectorButtonRadius * scaleX),
            border: Border.all(
              color: GraniTheme.selectorButtonBorder.withOpacity(0.96),
              width: 1,
            ),
            boxShadow: GraniTheme.selectorButtonShadow,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: GraniTheme.selectorButtonIconSize * scaleX,
                height: GraniTheme.selectorButtonIconSize * scaleY,
                child: Center(child: icon),
              ),
              SizedBox(width: GraniTheme.selectorButtonIconGap * scaleX),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: 'Montserrat',
                    fontWeight: FontWeight.w600,
                    fontSize: GraniTheme.selectorButtonTextSize * scaleX,
                    letterSpacing: 0,
                    height: 1.05,
                    color: GraniTheme.primaryText,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectorBottomSheet extends StatelessWidget {
  const _SelectorBottomSheet({
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screenWidth = media.size.width;
    final screenHeight = media.size.height;
    const designWidth = 412.0;
    final scaleX = screenWidth / designWidth;
    final scaleY = screenHeight / 917.0;

    return DraggableScrollableSheet(
      initialChildSize: 0.42,
      minChildSize: 0.32,
      maxChildSize: 0.68,
      builder: (context, scrollController) {
        return ClipRRect(
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(18 * scaleX),
            topRight: Radius.circular(18 * scaleX),
          ),
          child: Container(
            decoration: const BoxDecoration(
              gradient: GraniTheme.startScreenBackgroundGradient,
            ),
            child: Stack(
              children: [
                Positioned(
                  top: 31 * scaleY,
                  left: (screenWidth - 69 * scaleX) / 2,
                  child: Container(
                    width: 69 * scaleX,
                    height: 4 * scaleY,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Positioned(
                  top: 58 * scaleY,
                  left: 31 * scaleX,
                  child: Text(
                    title,
                    style: GraniTheme.headingSmall.copyWith(
                      fontSize: 24 * scaleX,
                      letterSpacing: 0,
                      height: 0.9,
                      color: GraniTheme.primaryText,
                    ),
                  ),
                ),
                Positioned(
                  top: 107 * scaleY,
                  left: (screenWidth - 312 * scaleX) / 2,
                  right: (screenWidth - 312 * scaleX) / 2,
                  bottom: media.padding.bottom + 32 * scaleY,
                  child: SingleChildScrollView(
                    controller: scrollController,
                    child: child,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _EmptySelectorState extends StatelessWidget {
  const _EmptySelectorState(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontFamily: 'Montserrat',
        fontWeight: FontWeight.w400,
        fontSize: 16,
        color: Color(0xFF192F3F),
      ),
    );
  }
}

String _localizedServerCountry(String rawCountry, Locale locale) {
  final value = rawCountry.trim();
  final lower = value.toLowerCase();
  final isRu = locale.languageCode.toLowerCase() == 'ru';
  const ru = <String, String>{
    'hu': 'Венгрия',
    'hungary': 'Венгрия',
    'gb': 'Великобритания',
    'uk': 'Великобритания',
    'united kingdom': 'Великобритания',
    'great britain': 'Великобритания',
    'de': 'Германия',
    'germany': 'Германия',
    'nl': 'Нидерланды',
    'netherlands': 'Нидерланды',
    'fi': 'Финляндия',
    'finland': 'Финляндия',
    'fr': 'Франция',
    'france': 'Франция',
    'pl': 'Польша',
    'poland': 'Польша',
    'польша': 'Польша',
    'se': 'Швеция',
    'sweden': 'Швеция',
    'швеция': 'Швеция',
    'sg': 'Сингапур',
    'singapore': 'Сингапур',
    'сингапур': 'Сингапур',
    'us': 'США',
    'usa': 'США',
    'united states': 'США',
    'сша': 'США',
  };
  const en = <String, String>{
    'hu': 'Hungary',
    'hungary': 'Hungary',
    'gb': 'United Kingdom',
    'uk': 'United Kingdom',
    'united kingdom': 'United Kingdom',
    'great britain': 'United Kingdom',
    'de': 'Germany',
    'germany': 'Germany',
    'nl': 'Netherlands',
    'netherlands': 'Netherlands',
    'fi': 'Finland',
    'finland': 'Finland',
    'fr': 'France',
    'france': 'France',
    'pl': 'Poland',
    'poland': 'Poland',
    'польша': 'Poland',
    'se': 'Sweden',
    'sweden': 'Sweden',
    'швеция': 'Sweden',
    'sg': 'Singapore',
    'singapore': 'Singapore',
    'сингапур': 'Singapore',
    'us': 'United States',
    'usa': 'United States',
    'united states': 'United States',
    'сша': 'United States',
  };
  final mapped = (isRu ? ru : en)[lower];
  if (mapped != null) return mapped;
  return FlagEmoji.localizedCountryName(value, locale);
}

String _localizedServerCity(String rawCity, Locale locale) {
  final value = rawCity.trim();
  final lower = value.toLowerCase();
  final isRu = locale.languageCode.toLowerCase() == 'ru';
  const ru = <String, String>{
    'budapest': 'Будапешт',
    'будапешт': 'Будапешт',
    'london': 'Лондон',
    'лондон': 'Лондон',
    'dublin': 'Дублин',
    'дублин': 'Дублин',
    'stockholm': 'Стокгольм',
    'стокгольм': 'Стокгольм',
    'falkenstein': 'Фалькенштайн',
    'фалькенштайн': 'Фалькенштайн',
    'frankfurt': 'Франкфурт',
    'amsterdam': 'Амстердам',
    'helsinki': 'Хельсинки',
    'paris': 'Париж',
    'warsaw': 'Варшава',
    'варшава': 'Варшава',
    'singapore': 'Сингапур',
    'сингапур': 'Сингапур',
    'new york': 'Нью-Йорк',
    'нью-йорк': 'Нью-Йорк',
    'нью йорк': 'Нью-Йорк',
  };
  const en = <String, String>{
    'budapest': 'Budapest',
    'будапешт': 'Budapest',
    'london': 'London',
    'лондон': 'London',
    'dublin': 'Dublin',
    'дублин': 'Dublin',
    'stockholm': 'Stockholm',
    'стокгольм': 'Stockholm',
    'falkenstein': 'Falkenstein',
    'фалькенштайн': 'Falkenstein',
    'frankfurt': 'Frankfurt',
    'amsterdam': 'Amsterdam',
    'helsinki': 'Helsinki',
    'paris': 'Paris',
    'warsaw': 'Warsaw',
    'варшава': 'Warsaw',
    'singapore': 'Singapore',
    'сингапур': 'Singapore',
    'new york': 'New York',
    'нью-йорк': 'New York',
    'нью йорк': 'New York',
  };
  final mapped = (isRu ? ru : en)[lower];
  return mapped ?? value;
}

String _localizedServerLabel(SimpleVpnServer? server, Locale locale) {
  if (server == null) {
    return locale.languageCode.toLowerCase() == 'ru' ? 'Сервер' : 'Server';
  }
  final city =
      _localizedServerCity(server.localizedCity(locale.languageCode), locale);
  final country = _localizedServerCountry(
      server.localizedCountry(locale.languageCode), locale);
  if (city.isEmpty) return country;
  return '$city, $country';
}

class _ServerSheetRow extends StatelessWidget {
  const _ServerSheetRow({
    required this.server,
    required this.locale,
    required this.selected,
    required this.onTap,
  });

  final SimpleVpnServer server;
  final Locale locale;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final countryName = _localizedServerCountry(
        server.localizedCountry(locale.languageCode), locale);
    final city =
        _localizedServerCity(server.localizedCity(locale.languageCode), locale);
    final title = city.isNotEmpty ? city : countryName;
    final subtitle = city.isNotEmpty ? countryName : server.ipAddress;
    return _SelectorOptionRow(
      leading: Text(
        FlagEmoji.getFlagEmoji(server.countryCode.isNotEmpty
            ? server.countryCode
            : server.country),
        style: const TextStyle(fontSize: 20),
      ),
      title: title,
      subtitle: subtitle,
      selected: selected,
      onTap: onTap,
    );
  }
}

class _ProtocolSheetRow extends StatelessWidget {
  const _ProtocolSheetRow({
    required this.protocol,
    required this.selected,
    required this.onTap,
  });

  final SimpleVpnProtocol protocol;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _SelectorOptionRow(
      leading: Icon(_simpleProtocolIcon(protocol.id),
          color: const Color(0xFF192F3F), size: 20),
      title: _protocolTitle(context, protocol.id, protocol.label),
      subtitle: Text(_protocolSubtitle(context, protocol.id)),
      selected: selected,
      onTap: onTap,
    );
  }

  String _protocolSubtitle(BuildContext context, String id) {
    switch (id) {
      case 'vless_ws':
        return context.l10n.protocolSheetVlessWsSubtitle;
      case 'hysteria2':
        return context.l10n.protocolSheetHysteria2Subtitle;
      case 'graniwg':
        return context.l10n.protocolSheetGraniWgSubtitle;
      default:
        return context.l10n.protocolSheetFallbackSubtitle;
    }
  }
}

String _protocolTitle(BuildContext context, String id, String fallback) {
  switch (id) {
    case 'vless_ws':
      return context.l10n.protocolNameVlessWs;
    case 'hysteria2':
      return context.l10n.protocolNameHysteria2;
    case 'graniwg':
      return context.l10n.protocolNameGraniWg;
    default:
      return fallback;
  }
}

IconData _simpleProtocolIcon(String id) {
  switch (id) {
    case 'vless_ws':
      return Icons.route_outlined;
    case 'hysteria2':
      return Icons.bolt_outlined;
    case 'graniwg':
      return Icons.shield_outlined;
    default:
      return Icons.tune;
  }
}

class _SelectorOptionRow extends StatelessWidget {
  const _SelectorOptionRow({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final Widget leading;
  final String title;
  final Object subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(GraniTheme.profileCardRadius),
      child: Container(
        constraints: const BoxConstraints(minHeight: 60),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          gradient: GraniTheme.surfaceControlGradient,
          borderRadius: BorderRadius.circular(GraniTheme.profileCardRadius),
          border: Border.all(
            color: GraniTheme.surfaceControlBorder.withOpacity(0.88),
            width: 1,
          ),
          boxShadow: GraniTheme.surfaceControlShadowStrong,
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                gradient: GraniTheme.surfaceControlGradient,
                borderRadius: BorderRadius.circular(13),
                border: Border.all(
                  color: GraniTheme.surfaceControlBorder.withOpacity(0.72),
                  width: 1,
                ),
              ),
              child: Center(child: leading),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Montserrat',
                      fontWeight: FontWeight.w500,
                      fontSize: 16,
                      height: 1.1,
                      color: Color(0xFF192F3F),
                    ),
                  ),
                  const SizedBox(height: 3),
                  subtitle is Widget
                      ? subtitle as Widget
                      : Text(
                          subtitle.toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Montserrat',
                            fontWeight: FontWeight.w400,
                            fontSize: 12,
                            height: 1.1,
                            color: Color(0xFF6F8194),
                          ),
                        ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Icon(
              selected ? Icons.check_circle : Icons.circle_outlined,
              color: selected
                  ? GraniTheme.connectedStatus
                  : GraniTheme.secondaryText,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

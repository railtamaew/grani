import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../services/auth_service.dart';
import '../../services/vpn_service.dart';
import '../bottom_sheet_profile.dart';
import '../../widgets/button_connection.dart';
import '../../widgets/connection_block.dart';
import '../../widgets/adaptive_text.dart';
import '../../widgets/ui_density.dart';
import '../../widgets/error_banner.dart';
import '../../widgets/snackbar_utils.dart';
import '../../widgets/vpn_top_bar.dart';
import '../../config/app_config.dart';
import '../../core/vpn_state_machine.dart';
import '../../core/vpn/connection_action_orchestrator.dart';
import '../../core/vpn/button_connection_state_mapper.dart';
import '../../core/vpn/connection_ui_action_applier.dart';
import '../../core/vpn/connection_tap_flow.dart';
import '../../theme.dart';
import 'vpn_shell_ui_helpers.dart';
import '../../l10n/l10n.dart';

/// Главный экран для пользователей с активной подпиской (Figma 958:337).
/// Стилистика совпадает с Trial: градиент фона, «Скорость», кнопка без подложки,
/// блок сервер/протокол с отступами по макету (ConnectionBlock, отступы 39/53).
/// Ошибки показываются баннером (красный текст на светлом фоне), как на Trial.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _errorMessage;
  ConnectionActionOrchestrator? _connectionOrchestrator;
  ConnectionTapFlow? _tapFlow;

  static String _getTitle(BuildContext context, ButtonConnectionState state) {
    final l10n = context.l10n;
    switch (state) {
      case ButtonConnectionState.off:
      case ButtonConnectionState.error:
        return l10n.homeSubscriptionActive;
      case ButtonConnectionState.on:
        return l10n.homeSubscriptionActive;
      case ButtonConnectionState.connecting:
        return l10n.homeConnecting;
      case ButtonConnectionState.disconnecting:
        return l10n.homeDisconnecting;
    }
  }

  static String _getSubtitle(
    BuildContext context,
    ButtonConnectionState state,
    VpnService vpnService,
  ) {
    final l10n = context.l10n;
    switch (state) {
      case ButtonConnectionState.off:
        return l10n.homeServiceReady;
      case ButtonConnectionState.error:
        return l10n.homeConnectionFailed;
      case ButtonConnectionState.on:
        return l10n.homeConnectionActive;
      case ButtonConnectionState.connecting:
        return VpnShellUiHelpers.connectingSubtitle(
          vpnService,
          l10n,
          waitTrafficHintWhenConnected: true,
        );
      case ButtonConnectionState.disconnecting:
        return l10n.homeDisconnectingSubtitle;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _connectionOrchestrator ??= ConnectionActionOrchestrator(
      vpnService: Provider.of<VpnService>(context, listen: false),
      authService: Provider.of<AuthService>(context, listen: false),
      startTrialTimer: false,
      disconnectSource: 'home_connection_button',
    );
    _tapFlow ??= ConnectionTapFlow(
      orchestrator: _connectionOrchestrator!,
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

    return Consumer<VpnService>(
      builder: (context, vpnService, _) {
        final buttonState = ButtonConnectionStateMapper.fromVpnSessionState(
          vpnService.vpnUiSessionState,
          errorMessage: _errorMessage,
        );
        final title = _getTitle(context, buttonState);
        final subtitle = _getSubtitle(context, buttonState, vpnService);
        final flowBadge =
            VpnShellUiHelpers.connectionFlowBadge(vpnService, context.l10n);
        final isConnecting = buttonState == ButtonConnectionState.connecting;
        final isDisconnecting = buttonState == ButtonConnectionState.disconnecting;
        final isConnectingOrDisconnecting = isConnecting || isDisconnecting;
        final titleBlockWidth = 347 * scaleX;

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
                    // Зона под системной навигацией — цвет фона по макету #F7F9FA
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        height: safeBottom + GraniTheme.navigationBarHeight * scaleY,
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
                            context.l10n.profileSharePlayStoreMessage(AppConfig.sharePlayStoreUrl),
                          );
                        } catch (_) {
                          if (context.mounted) {
                            showErrorSnackBar(context, context.l10n.profileShareFailed);
                          }
                        }
                      },
                    ),
                    // Заголовок и подзаголовок привязаны (не скроллятся) в состояниях off/on
                    if (!isConnectingOrDisconnecting)
                      Positioned(
                        top: (12 + 39 + 12 + GraniTheme.trialTitleBlockTopGap) * scaleY,
                        left: (screenWidth - titleBlockWidth) / 2,
                        child: SizedBox(
                          width: titleBlockWidth,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AdaptiveTitleText(
                                text: title,
                                maxLines: tokens.titleMaxLines,
                                minScale: tokens.titleMinScale,
                                style: TextStyle(
                                  fontFamily: 'Montserrat',
                                  fontWeight: FontWeight.w400,
                                  fontSize: GraniTheme.trialTitleFontSize * scaleX,
                                  height: 28.8 / GraniTheme.trialTitleFontSize,
                                  letterSpacing: -1.28 * scaleX,
                                  color: const Color(0xFF192F3F),
                                ),
                              textAlign: TextAlign.center,
                              ),
                              SizedBox(height: tokens.textGap * scaleY),
                              AdaptiveSubtitleText(
                                text: subtitle,
                                maxLines: tokens.subtitleMaxLines,
                                style: TextStyle(
                                  fontFamily: 'Montserrat',
                                  fontWeight: FontWeight.w300,
                                  fontSize: 16 * scaleX,
                                  height: 15.52 / 16,
                                  letterSpacing: 0.96 * scaleX,
                                  color: const Color(0xFF192F3F),
                                ),
                              textAlign: TextAlign.center,
                              ),
                              if (flowBadge != null) ...[
                                SizedBox(height: 8 * scaleY),
                                Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 10 * scaleX,
                                    vertical: 5 * scaleY,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.55),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    flowBadge,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: 'Montserrat',
                                      fontWeight: FontWeight.w500,
                                      fontSize: 12 * scaleX,
                                      color: const Color(0xFF192F3F),
                                    ),
                                  textAlign: TextAlign.center,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    if (isConnectingOrDisconnecting)
                      Positioned(
                        top: (12 + 39 + 12 + GraniTheme.trialTitleBlockTopGap) * scaleY,
                        left: (screenWidth - titleBlockWidth) / 2,
                        child: SizedBox(
                          width: titleBlockWidth,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AdaptiveTitleText(
                                text: title,
                                maxLines: tokens.titleMaxLines,
                                minScale: tokens.titleMinScale,
                                style: TextStyle(
                                  fontFamily: 'Montserrat',
                                  fontWeight: FontWeight.w400,
                                  fontSize: GraniTheme.trialTitleFontSize * scaleX,
                                  height: 28.8 / GraniTheme.trialTitleFontSize,
                                  letterSpacing: -1.28 * scaleX,
                                  color: const Color(0xFF192F3F),
                                  shadows: [
                                    Shadow(
                                      color: Colors.white.withOpacity(0.8),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                textAlign: TextAlign.center,
                              ),
                              SizedBox(height: tokens.textGap * scaleY),
                              AdaptiveSubtitleText(
                                text: subtitle,
                                maxLines: tokens.subtitleMaxLines,
                                style: TextStyle(
                                  fontFamily: 'Montserrat',
                                  fontWeight: FontWeight.w300,
                                  fontSize: 16 * scaleX,
                                  height: 15.52 / 16,
                                  letterSpacing: 0.96 * scaleX,
                                  color: const Color(0xFF192F3F),
                                  shadows: [
                                    Shadow(
                                      color: Colors.white.withOpacity(0.8),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                textAlign: TextAlign.center,
                              ),
                              if (flowBadge != null) ...[
                                SizedBox(height: 8 * scaleY),
                                Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 10 * scaleX,
                                    vertical: 5 * scaleY,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.55),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    flowBadge,
                                    style: TextStyle(
                                      fontFamily: 'Montserrat',
                                      fontWeight: FontWeight.w500,
                                      fontSize: 12 * scaleX,
                                      color: const Color(0xFF192F3F),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    // Блок подключения: Selector — rebuild только при изменении state/progress/speed
                    Positioned(
                      bottom: GraniTheme.vpnCardBottomMargin * scaleY + safeBottom,
                      left: (screenWidth - GraniTheme.backgroundBoxWidth * scaleX) / 2,
                      child: Selector<VpnService,
                          (
                            ButtonConnectionState,
                            String?,
                            int?,
                            double?,
                            bool?,
                            String?,
                          )>(
                        selector: (_, vpn) => (
                          ButtonConnectionStateMapper.fromVpnSessionState(
                            vpn.vpnUiSessionState,
                            errorMessage: _errorMessage,
                          ),
                          vpn.connectionProgress?.message,
                          vpn.connectionProgress?.percent,
                          vpn.currentSpeedMbps,
                          vpn.hasEverSeenTraffic,
                          _errorMessage,
                        ),
                        builder: (context, data, _) {
                          final l10n = context.l10n;
                          return ConnectionBlock(
                            scaleX: scaleX,
                            scaleY: scaleY,
                            timerText: null,
                            timerLabel: null,
                            showSpeedModule: true,
                            speedMbps: data.$4,
                            hasEverSeenTraffic: data.$5,
                            connectionState: data.$1,
                            progressMessage: VpnShellUiHelpers.friendlyProgressMessage(
                              data.$2,
                              l10n,
                            ),
                            progressPercent: data.$3,
                            errorMessage: data.$6,
                            onConnectionTap: () async {
                              await _handleConnectionTap(context, data.$1);
                            },
                          );
                        },
                      ),
                    ),
                    Positioned.fill(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: EdgeInsets.only(
                            bottom: GraniTheme.navigationBarHeight * scaleY + safeBottom + 20,
                          ),
                          child: ErrorBanner(
                            message: _errorMessage ?? '',
                            visible: _errorMessage != null,
                            onDismiss: () => setState(() => _errorMessage = null),
                          ),
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

  Future<void> _handleConnectionTap(
    BuildContext context,
    ButtonConnectionState state,
  ) async {
    final tapFlow = _tapFlow;
    if (tapFlow == null) return;
    final outcome = await tapFlow.handleTap(context, state);
    if (!mounted) return;
    ConnectionUiActionApplier.apply(
      context: context,
      action: outcome.action,
      setErrorMessage: (msg) => setState(() => _errorMessage = msg),
    );
  }
}

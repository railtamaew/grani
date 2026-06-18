import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../theme.dart';
import 'button_connection.dart';
import 'server_selector_button.dart';
import 'protocol_selector_button.dart';

/// Блок подключения по макету Figma 562:732, 939:555: таймер (опционально), скорость, кнопка, сервер/протокол.
/// Отступы: «Скорость» → кнопка 39 px, кнопка → ряд 53 px. Без фиксированной высоты.
///
/// [progressMessage] — при connecting показывается на кнопке вместо «Подключение…».
/// [showCancelHint] — показывать «Нажмите для отмены» под кнопкой при connecting/disconnecting.
class ConnectionBlock extends StatelessWidget {
  final double scaleX;
  final double scaleY;
  final bool? showSpeedModule;
  final double? speedMbps;
  final bool? hasEverSeenTraffic;
  final String? timerText;
  final String? timerLabel;
  final ButtonConnectionState? connectionState;
  final String? progressMessage;
  final String? errorMessage;
  final int? progressPercent;
  final bool showCancelHint;
  final bool compactMode;
  final VoidCallback? onConnectionTap;
  final void Function(String)? onServerLoadError;

  const ConnectionBlock({
    super.key,
    required this.scaleX,
    required this.scaleY,
    this.showSpeedModule,
    this.speedMbps,
    this.hasEverSeenTraffic,
    this.timerText,
    this.timerLabel,
    this.connectionState,
    this.progressMessage,
    this.errorMessage,
    this.progressPercent,
    this.showCancelHint = true,
    this.compactMode = true,
    this.onConnectionTap,
    this.onServerLoadError,
  });

  bool _showStageTimeline(ButtonConnectionState state) {
    return state == ButtonConnectionState.connecting ||
        state == ButtonConnectionState.disconnecting;
  }

  /// Плавная шкала 0–100 % по данным [VpnService] (этапы подключения), иначе неопределённый прогресс при отключении.
  Widget _buildLinearStageProgress(
    AppLocalizations l10n,
    double scaleX,
    double scaleY,
    int? progressPercent,
    ButtonConnectionState state,
  ) {
    final inactive = GraniTheme.secondaryText.withOpacity(0.25);
    const active = Color(0xFF192F3F);
    final double? value = state == ButtonConnectionState.disconnecting
        ? null
        : (progressPercent != null
            ? progressPercent.clamp(0, 100) / 100.0
            : null);
    return Semantics(
      label: l10n.connectionStagesProgressSemantic,
      child: SizedBox(
        width: 220 * scaleX,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: value,
            minHeight: 4 * scaleY,
            backgroundColor: inactive,
            color: active,
          ),
        ),
      ),
    );
  }

  /// Текст для отображения скорости/статуса: при подключении и трафике — скорость;
  /// в простое после трафика — «Соединение стабильно»; до первого трафика — «Ожидание трафика...»
  String _speedLabel(ButtonConnectionState state, AppLocalizations l10n) {
    if (state != ButtonConnectionState.on) {
      return l10n.connectionSpeedZero;
    }
    final speed = speedMbps ?? 0.0;
    final hasTraffic = hasEverSeenTraffic ?? false;
    if (speed > 0.1) {
      return l10n.connectionSpeedMbps(speed.toStringAsFixed(1));
    }
    if (hasTraffic) {
      return l10n.connectionStable;
    }
    return l10n.connectionWaitingTraffic;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = connectionState ?? ButtonConnectionState.off;
    final compact = compactMode;
    final showTimeline = !compact && _showStageTimeline(state);
    return SizedBox(
      width: GraniTheme.backgroundBoxWidth * scaleX,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (!compact && timerText != null && timerLabel != null)
            Padding(
              padding: EdgeInsets.only(bottom: 12 * scaleY),
              child: Center(
                child: Text(
                  '$timerLabel$timerText',
                  style: TextStyle(
                    fontFamily: 'Montserrat',
                    fontWeight: GraniTheme.trialTimerFontWeight,
                    fontSize: GraniTheme.trialTimerFontSize * scaleX,
                    color: GraniTheme.primaryText,
                  ),
                ),
              ),
            ),
          if (!compact && showSpeedModule != false)
            Padding(
              padding: EdgeInsets.only(
                  bottom: GraniTheme.connectionBlockGapSpeedToButton * scaleY),
              child: Center(
                child: Text(
                  _speedLabel(state, l10n),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Montserrat',
                    fontWeight: GraniTheme.trialTimerFontWeight,
                    fontSize: GraniTheme.trialSpeedFontSize * scaleX,
                    color: GraniTheme.primaryText,
                  ),
                ),
              ),
            ),
          Center(
            child: ButtonConnection(
              state: state,
              progressMessage: progressMessage,
              errorMessage: errorMessage,
              progressPercent: progressPercent,
              onTap: onConnectionTap,
              scaleX: scaleX,
              scaleY: scaleY,
            ),
          ),
          Padding(
            padding: EdgeInsets.only(top: 6 * scaleY, bottom: 6 * scaleY),
            child: Opacity(
              opacity: (!compact &&
                      showCancelHint &&
                      (state == ButtonConnectionState.connecting ||
                          state == ButtonConnectionState.disconnecting ||
                          (state == ButtonConnectionState.error &&
                              errorMessage != null)))
                  ? 1.0
                  : 0.0,
              child: Text(
                (state == ButtonConnectionState.error && errorMessage != null)
                    ? l10n.connectionTapRetry
                    : l10n.connectionTapCancel,
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontWeight: FontWeight.w400,
                  fontSize: 13 * scaleX,
                  color: GraniTheme.secondaryText,
                ),
              ),
            ),
          ),
          Visibility(
            visible: showTimeline,
            // Фиксируем высоту: чтобы при появлении/исчезновении "этапов подключения"
            // кнопка не "прыгала" вверх из-за позиционирования блока от `bottom`.
            // Flutter Visibility: maintainSize ⇒ maintainAnimation ⇒ maintainState.
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: Padding(
              padding: EdgeInsets.only(bottom: 6 * scaleY),
              child: Column(
                children: [
                  _buildLinearStageProgress(
                    l10n,
                    scaleX,
                    scaleY,
                    progressPercent,
                    state,
                  ),
                  SizedBox(height: 6 * scaleY),
                  Text(
                    l10n.connectionStagesTitle,
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
          ),
          if (!compact)
            SizedBox(
                height: GraniTheme.connectionBlockGapButtonToControls * scaleY),
          if (!compact)
            IgnorePointer(
              ignoring: state == ButtonConnectionState.connecting ||
                  state == ButtonConnectionState.disconnecting,
              child: Opacity(
                opacity: (state == ButtonConnectionState.connecting ||
                        state == ButtonConnectionState.disconnecting)
                    ? 0.72
                    : 1.0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ServerSelectorButton(
                      scaleX: scaleX,
                      scaleY: scaleY,
                      onServerLoadError: onServerLoadError,
                    ),
                    SizedBox(width: GraniTheme.selectorButtonGap * scaleX),
                    ProtocolSelectorButton(
                      scaleX: scaleX,
                      scaleY: scaleY,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

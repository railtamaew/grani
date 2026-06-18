import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../features/vpn/presentation/widgets/grani_connect_surface_button.dart';
import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';

/// Состояния кнопки подключения VPN (UI adapter для существующего connect-flow).
enum ButtonConnectionState {
  /// OFF — отключено, готово к подключению.
  off,

  /// CONNECTING — идёт подключение.
  connecting,

  /// DISCONNECTING — идёт отключение.
  disconnecting,

  /// CONNECTED — подключено.
  on,

  /// ERROR — ошибка подключения.
  error,
}

/// Единый adapter кнопки подключения/отключения VPN.
///
/// Бизнес-логика и состояние подключения остаются снаружи; виджет только
/// маппит существующий [ButtonConnectionState] на новый визуальный слой.
class ButtonConnection extends StatefulWidget {
  final ButtonConnectionState state;
  final VoidCallback? onTap;
  final String? progressMessage;

  /// Сообщение об ошибке при state == error.
  final String? errorMessage;

  /// Прогресс подключения 0-100. Оставлен для совместимости с текущим API.
  final int? progressPercent;
  final double size;
  final double scaleX;
  final double scaleY;

  const ButtonConnection({
    super.key,
    required this.state,
    this.onTap,
    this.progressMessage,
    this.errorMessage,
    this.progressPercent,
    this.size = 330,
    this.scaleX = 1.0,
    this.scaleY = 1.0,
  });

  @override
  State<ButtonConnection> createState() => _ButtonConnectionState();
}

class _ButtonConnectionState extends State<ButtonConnection> {
  DateTime? _lastTapAt;
  static const _tapDebounceMs = 400;

  void _onTap() {
    if (widget.onTap == null) return;
    final now = DateTime.now();
    if (_lastTapAt != null &&
        now.difference(_lastTapAt!).inMilliseconds < _tapDebounceMs) {
      return;
    }
    _lastTapAt = now;
    HapticFeedback.selectionClick();
    widget.onTap!();
  }

  @override
  void didUpdateWidget(ButtonConnection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state == ButtonConnectionState.connecting &&
        widget.state == ButtonConnectionState.on) {
      HapticFeedback.mediumImpact();
    }
    if (oldWidget.state == ButtonConnectionState.disconnecting &&
        widget.state == ButtonConnectionState.off) {
      HapticFeedback.mediumImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final canTap = widget.onTap != null;
    final isRu = Localizations.localeOf(context).languageCode == 'ru';
    return GraniConnectSurfaceButton(
      state: _surfaceState(widget.state),
      onPressed: canTap ? _onTap : null,
      title: _titleForState(widget.state, isRu),
      subtitle: _subtitleForState(widget.state, isRu),
      size: widget.size * widget.scaleX,
      semanticsLabel:
          _semanticsLabel(widget.state, widget.progressMessage, l10n),
      semanticsHint: (widget.state == ButtonConnectionState.connecting ||
              widget.state == ButtonConnectionState.disconnecting)
          ? l10n.semanticsVpnTapCancel
          : null,
    );
  }

  VpnConnectionState _surfaceState(ButtonConnectionState state) {
    switch (state) {
      case ButtonConnectionState.off:
        return VpnConnectionState.disconnected;
      case ButtonConnectionState.connecting:
        return VpnConnectionState.connecting;
      case ButtonConnectionState.disconnecting:
        return VpnConnectionState.disconnecting;
      case ButtonConnectionState.on:
        return VpnConnectionState.connected;
      case ButtonConnectionState.error:
        return VpnConnectionState.error;
    }
  }

  String _titleForState(ButtonConnectionState state, bool isRu) {
    switch (state) {
      case ButtonConnectionState.off:
        return isRu ? 'Подключить' : 'Connect';
      case ButtonConnectionState.connecting:
        return isRu ? 'Подключение...' : 'Connecting...';
      case ButtonConnectionState.disconnecting:
        return isRu ? 'Отключение...' : 'Disconnecting...';
      case ButtonConnectionState.on:
        return isRu ? 'Подключено' : 'Connected';
      case ButtonConnectionState.error:
        return isRu ? 'Повторить' : 'Retry';
    }
  }

  String _subtitleForState(ButtonConnectionState state, bool isRu) {
    switch (state) {
      case ButtonConnectionState.off:
        return isRu ? 'Нажмите для защиты' : 'Tap to protect';
      case ButtonConnectionState.connecting:
        return isRu ? 'Создаём защищённый канал' : 'Creating secure channel';
      case ButtonConnectionState.disconnecting:
        return isRu ? 'Завершаем соединение' : 'Closing connection';
      case ButtonConnectionState.on:
        return isRu ? 'Соединение защищено' : 'Connection protected';
      case ButtonConnectionState.error:
        return isRu ? 'Проверьте сеть' : 'Check network';
    }
  }

  String _semanticsLabel(
    ButtonConnectionState state,
    String? progressMessage,
    AppLocalizations l10n,
  ) {
    switch (state) {
      case ButtonConnectionState.off:
        return l10n.semanticsVpnConnect;
      case ButtonConnectionState.connecting:
        return progressMessage ?? l10n.semanticsVpnConnecting;
      case ButtonConnectionState.disconnecting:
        return l10n.semanticsVpnDisconnecting;
      case ButtonConnectionState.on:
        return l10n.semanticsVpnConnectedTapDisconnect;
      case ButtonConnectionState.error:
        return l10n.semanticsVpnErrorRetry;
    }
  }
}

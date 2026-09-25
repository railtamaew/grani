import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../simple_vpn/simple_vpn_controller.dart';
import 'native_vpn_service.dart';

/// Windows tray is a view of the existing controller, never a second VPN owner.
class DesktopIntegration {
  static const _channel = MethodChannel('com.granivpn.desktop/controls');
  static SimpleVpnController? _controller;
  static String _locale = 'en';
  static String? _lastState;
  static bool _quitting = false;
  static bool get enabled =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  static void initialize() {
    if (!enabled) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'toggle') {
        await toggle();
      } else if (call.method == 'website') {
        await launchUrl(Uri.parse('https://granilink.com'),
            mode: LaunchMode.externalApplication);
      } else if (call.method == 'quit') {
        await _quit();
      }
    });
    _publish();
  }

  static void bind(SimpleVpnController controller, String locale) {
    if (!enabled) return;
    if (!identical(_controller, controller)) {
      _controller?.removeListener(_publish);
      _controller = controller;
      controller.addListener(_publish);
    }
    _locale = locale;
    _publish();
  }

  static void unbind(SimpleVpnController controller) {
    if (!enabled || !identical(_controller, controller)) return;
    controller.removeListener(_publish);
    _controller = null;
    _publish();
  }

  static Future<void> toggle() async {
    final controller = _controller;
    if (!enabled || _quitting || controller == null || controller.isBusy)
      return;
    await controller.toggle(source: 'windows_tray');
  }

  static Future<void> _quit() async {
    if (_quitting) return;
    _quitting = true;
    _publish();
    try {
      // Controller records the session stop. The final native disconnect also
      // covers login/startup screens and is queued behind any pending start.
      await _controller?.disconnect(source: 'windows_tray', reason: 'user');
      final stopped = await NativeVpnService.disconnect(
        source: 'windows_tray',
        reason: 'app_exit',
      );
      if (!stopped) throw StateError('Windows VPN did not stop');
      await _channel.invokeMethod<void>('finishQuit');
    } catch (error) {
      _quitting = false;
      _lastState = null;
      await _sendState({
        'status': _locale == 'ru'
            ? 'Не удалось отключить VPN — откройте GRANI'
            : 'VPN could not stop — open GRANI',
        'location': '',
        'connected': _controller?.isConnected ?? false,
        'busy': false,
        'canToggle': _controller != null,
        'locale': _locale,
      });
    }
  }

  static void _publish() {
    if (!enabled) return;
    final controller = _controller;
    final ru = _locale == 'ru';
    final busy = _quitting || (controller?.isBusy ?? false);
    final state = controller?.state;
    final status = _quitting
        ? (ru ? 'Завершаем работу…' : 'Quitting…')
        : switch (state) {
            SimpleVpnState.connected => ru ? 'Защищено' : 'Protected',
            SimpleVpnState.connecting => ru ? 'Подключение…' : 'Connecting…',
            SimpleVpnState.disconnecting =>
              ru ? 'Отключение…' : 'Disconnecting…',
            SimpleVpnState.error =>
              ru ? 'Ошибка подключения' : 'Connection failed',
            SimpleVpnState.disconnected => ru ? 'VPN отключён' : 'VPN is off',
            null => ru ? 'Откройте приложение' : 'Open the app',
          };
    final location = controller == null
        ? ''
        : '${controller.serverName} · ${controller.selectedProtocol.label}';
    final signature = '$status|$location|$busy|${controller != null}|$_locale';
    if (_lastState == signature) return;
    _lastState = signature;
    unawaited(
      _sendState({
        'status': status,
        'location': location,
        'connected': controller?.isConnected ?? false,
        'busy': busy,
        'canToggle': controller != null && !busy,
        'locale': _locale,
      }),
    );
  }

  static Future<void> _sendState(Map<String, Object> state) async {
    try {
      await _channel.invokeMethod<void>('updateState', state);
    } on MissingPluginException {
      // Allows widget tests and older development runners to render the app.
    } on PlatformException {
      _lastState = null;
    }
  }
}

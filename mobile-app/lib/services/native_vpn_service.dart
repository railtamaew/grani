import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

class NativeVpnService {
  static const MethodChannel _channel =
      MethodChannel('com.granivpn.mobile/vpn');

  static bool get _isAndroidNativeVpn =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get _isWindowsNativeVpn =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  static bool get _isMacOSNativeVpn =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  static bool get _supportsNativeVpnChannel =>
      _isAndroidNativeVpn || _isWindowsNativeVpn || _isMacOSNativeVpn;

  static VpnUnsupportedPlatformException _unsupportedPlatformException() {
    return VpnUnsupportedPlatformException(
      'GRANI VPN desktop tunnel is not implemented yet for '
      '${defaultTargetPlatform.name}.',
    );
  }

  /// Счётчики MethodChannel к нативному VPN (диагностика: до/после event-driven).
  static int _getStatusCallCount = 0;
  static int _getTrafficStatsCallCount = 0;

  static int get getStatusCallCount => _getStatusCallCount;

  static int get getTrafficStatsCallCount => _getTrafficStatsCallCount;

  /// Только для тестов.
  static void resetChannelCallCountsForTests() {
    _getStatusCallCount = 0;
    _getTrafficStatsCallCount = 0;
  }

  /// Сводка для лога: сколько раз за сессию дергали канал (см. [resetChannelCallCountsForTests] в начале сессии при необходимости).
  static Map<String, int> channelCallSnapshot() => {
        'getStatus': _getStatusCallCount,
        'getTrafficStats': _getTrafficStatsCallCount,
      };

  static Future<Map<String, dynamic>> getDesktopVpnDiagnostics() async {
    if (!_supportsNativeVpnChannel) {
      return <String, dynamic>{
        'platform': defaultTargetPlatform.name,
        'supported': false,
      };
    }
    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('getDesktopVpnDiagnostics');
      return result == null
          ? <String, dynamic>{}
          : result.map((key, value) => MapEntry(key.toString(), value));
    } catch (e) {
      return <String, dynamic>{
        'platform': defaultTargetPlatform.name,
        'diagnostics_error': e.toString(),
      };
    }
  }

  /// События изменения состояния VPN с нативного [GraniVpnService] (без polling [getStatus]).
  static const EventChannel _vpnStateChannel =
      EventChannel('com.granivpn.mobile/vpn_state');

  /// Карта: `connected` (bool), `service_state` (String), `ts` (int),
  /// `emit_type` (`state` | `traffic` | `connectivity_probe`).
  /// Для `traffic` — `rx_bytes`, `tx_bytes`; для `connectivity_probe` — поля пробы (см. GraniVpnService).
  static Stream<Map<dynamic, dynamic>> get nativeVpnStateEvents {
    if (!_isAndroidNativeVpn) {
      return const Stream<Map<dynamic, dynamic>>.empty();
    }
    return _vpnStateChannel.receiveBroadcastStream().map((dynamic e) {
      if (e is Map) {
        return Map<dynamic, dynamic>.from(e);
      }
      return <dynamic, dynamic>{};
    });
  }

  /// Подключение к VPN с конфигурацией
  ///
  /// Поддерживает:
  /// - WireGuard: конфигурация в формате [Interface]/[Peer]
  /// - XRay: JSON конфигурация (полный формат XRay или упрощенный клиентский формат)
  ///
  /// [protocol] — необязательная подсказка для нативного слоя
  /// (например, wireguard, xray_vless, xray_vmess, xray_reality).
  /// [mtu] — MTU для TUN (для мобильной сети обычно 1280, иначе возможна нулевая скорость).
  /// [connectionSessionId] — сквозной id сессии подключения (Dart ↔ logcat ↔ бэкенд).
  /// [source] — происхождение старта нативного VPN (например `first_connect`, `ui_tap`).
  /// [runtimeContract] / [correlationId] — из ответа `create-client`; нативный слой делает
  /// fail-fast при `runtime_contract.has_mismatch` до запуска VPN.
  static Future<bool> connect(
    String config, {
    String? protocol,
    int? mtu,
    String? connectionSessionId,
    String? source,
    Map<String, dynamic>? runtimeContract,
    String? correlationId,
  }) async {
    if (!_isAndroidNativeVpn) {
      throw _unsupportedPlatformException();
    }
    try {
      final args = <String, dynamic>{
        'config': config,
      };
      if (protocol != null && protocol.isNotEmpty) {
        args['protocol'] = protocol;
      }
      if (mtu != null && mtu > 0) {
        args['mtu'] = mtu;
      }
      if (connectionSessionId != null && connectionSessionId.isNotEmpty) {
        args['connection_session_id'] = connectionSessionId;
      }
      if (source != null && source.isNotEmpty) {
        args['source'] = source;
      }
      if (runtimeContract != null && runtimeContract.isNotEmpty) {
        args['runtime_contract'] = runtimeContract;
      }
      if (correlationId != null && correlationId.isNotEmpty) {
        args['correlation_id'] = correlationId;
      }
      final result = await _channel.invokeMethod<bool>('connect', args);
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('Ошибка подключения VPN: ${e.message}');
      if (e.code == 'PERMISSION_DENIED') {
        // Получаем понятное сообщение для пользователя из details
        final userMessage = e.details is Map
            ? (e.details as Map)['userMessage'] as String?
            : null;
        throw VpnPermissionException(userMessage ??
            'VPN разрешение отклонено. Для работы VPN необходимо предоставить разрешение в настройках системы.');
      }
      if (e.code == 'CONFIG_MISMATCH') {
        final d = e.details;
        List<String> fields = const [];
        String? cid;
        if (d is Map) {
          cid = d['correlation_id']?.toString();
          final raw = d['mismatch_fields'];
          if (raw is List) {
            fields = raw
                .map((x) => x.toString())
                .where((s) => s.isNotEmpty)
                .toList();
          }
        }
        throw ConfigMismatchException(
          e.message ?? 'Несовместимый VPN-конфиг',
          correlationId: cid,
          mismatchFields: fields,
        );
      }
      throw VpnException('Ошибка подключения VPN: ${e.message}');
    } catch (e) {
      debugPrint('Неожиданная ошибка подключения VPN: $e');
      throw VpnException('Неожиданная ошибка: $e');
    }
  }

  /// Запрашивает системное VPN-разрешение заранее, без запуска туннеля.
  static Future<bool> requestPermission() async {
    if (!_supportsNativeVpnChannel) {
      return true;
    }
    try {
      final result = await _channel.invokeMethod<bool>('requestPermission');
      return result ?? false;
    } on PlatformException catch (e) {
      if (e.code == 'PERMISSION_DENIED') {
        final userMessage = e.details is Map
            ? (e.details as Map)['userMessage'] as String?
            : null;
        throw VpnPermissionException(
          userMessage ??
              'VPN разрешение отклонено. Для работы VPN необходимо предоставить разрешение в настройках системы.',
        );
      }
      throw VpnException('Ошибка запроса VPN разрешения: ${e.message}');
    } catch (e) {
      throw VpnException('Неожиданная ошибка запроса VPN разрешения: $e');
    }
  }

  /// Подключение через embedded AmneziaWG backend.
  static Future<bool> connectAmneziaWg(
    String config, {
    String? connectionSessionId,
    String? source,
  }) async {
    if (!_supportsNativeVpnChannel) {
      throw _unsupportedPlatformException();
    }
    try {
      final args = <String, dynamic>{'config': config};
      if (connectionSessionId != null && connectionSessionId.isNotEmpty) {
        args['connection_session_id'] = connectionSessionId;
      }
      if (source != null && source.isNotEmpty) {
        args['source'] = source;
      }
      if (_isAndroidNativeVpn) {
        final splitMode = await getSplitTunnelMode();
        final splitPackages = await getSplitTunnelExcludedApps();
        final directDomains = await getSplitTunnelDirectDomains();
        args['split_tunnel_mode'] = splitMode;
        args['split_tunnel_packages'] = splitPackages;
        args['split_tunnel_direct_domains'] = directDomains;
      }
      final result =
          await _channel.invokeMethod<bool>('connectAmneziaWg', args);
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('Ошибка подключения AmneziaWG: ${e.message}');
      if (e.code == 'PERMISSION_DENIED') {
        final userMessage = e.details is Map
            ? (e.details as Map)['userMessage'] as String?
            : null;
        throw VpnPermissionException(
          userMessage ??
              'VPN разрешение отклонено. Для работы VPN необходимо предоставить разрешение в настройках системы.',
        );
      }
      if (_isWindowsNativeVpn || _isMacOSNativeVpn) {
        final diagnostics = await getDesktopVpnDiagnostics();
        final diagnosticText = diagnostics.entries
            .where((entry) =>
                entry.value != null && entry.value.toString().isNotEmpty)
            .map((entry) => '${entry.key}=${entry.value}')
            .join('; ');
        throw VpnException(
          'Ошибка подключения AmneziaWG: ${e.message}. '
          'Desktop diagnostics: $diagnosticText',
        );
      }
      throw VpnException('Ошибка подключения AmneziaWG: ${e.message}');
    } catch (e) {
      debugPrint('Неожиданная ошибка подключения AmneziaWG: $e');
      throw VpnException('Неожиданная ошибка AmneziaWG: $e');
    }
  }

  /// Starts the official Hysteria 2 client in Windows TUN mode.
  static Future<bool> connectHysteria2(
    String config, {
    String? connectionSessionId,
    String? source,
  }) async {
    if (!_isWindowsNativeVpn) {
      throw _unsupportedPlatformException();
    }
    try {
      final args = <String, dynamic>{'config': config};
      if (connectionSessionId != null && connectionSessionId.isNotEmpty) {
        args['connection_session_id'] = connectionSessionId;
      }
      if (source != null && source.isNotEmpty) {
        args['source'] = source;
      }
      final result = await _channel.invokeMethod<bool>(
        'connectHysteria2',
        args,
      );
      return result ?? false;
    } on PlatformException catch (e) {
      final diagnostics = await getDesktopVpnDiagnostics();
      final diagnosticText = diagnostics.entries
          .where((entry) =>
              entry.value != null && entry.value.toString().isNotEmpty)
          .map((entry) => '${entry.key}=${entry.value}')
          .join('; ');
      throw VpnException(
        'Ошибка подключения Hysteria 2: ${e.message}. '
        'Desktop diagnostics: $diagnosticText',
      );
    } catch (e) {
      if (e is VpnException) rethrow;
      throw VpnException('Неожиданная ошибка Hysteria 2: $e');
    }
  }

  /// Starts the official sing-box client in Windows VLESS WS TUN mode.
  static Future<bool> connectVless(
    String config, {
    String? connectionSessionId,
    String? source,
  }) async {
    if (!_isWindowsNativeVpn) {
      throw _unsupportedPlatformException();
    }
    try {
      final args = <String, dynamic>{'config': config};
      if (connectionSessionId != null && connectionSessionId.isNotEmpty) {
        args['connection_session_id'] = connectionSessionId;
      }
      if (source != null && source.isNotEmpty) {
        args['source'] = source;
      }
      final result = await _channel.invokeMethod<bool>('connectVless', args);
      return result ?? false;
    } on PlatformException catch (e) {
      final diagnostics = await getDesktopVpnDiagnostics();
      final diagnosticText = diagnostics.entries
          .where((entry) =>
              entry.value != null && entry.value.toString().isNotEmpty)
          .map((entry) => '${entry.key}=${entry.value}')
          .join('; ');
      throw VpnException(
        'Ошибка подключения VLESS: ${e.message}. '
        'Desktop diagnostics: $diagnosticText',
      );
    } catch (e) {
      if (e is VpnException) rethrow;
      throw VpnException('Неожиданная ошибка VLESS: $e');
    }
  }

  /// Отключение embedded AmneziaWG backend.
  static Future<bool> disconnectAmneziaWg({
    String? reason,
    String? source,
    String? connectionSessionId,
  }) async {
    if (!_supportsNativeVpnChannel) {
      return true;
    }
    try {
      final args = <String, dynamic>{};
      if (reason != null && reason.isNotEmpty) args['reason'] = reason;
      if (source != null && source.isNotEmpty) args['source'] = source;
      if (connectionSessionId != null && connectionSessionId.isNotEmpty) {
        args['connection_session_id'] = connectionSessionId;
      }
      final result =
          await _channel.invokeMethod<bool>('disconnectAmneziaWg', args);
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('Ошибка отключения AmneziaWG: ${e.message}');
      throw VpnException('Ошибка отключения AmneziaWG: ${e.message}');
    } catch (e) {
      debugPrint('Неожиданная ошибка отключения AmneziaWG: $e');
      throw VpnException('Неожиданная ошибка AmneziaWG: $e');
    }
  }

  /// Отключение от VPN.
  /// [reason] и [source] прокидываются в native-логи для диагностики инициатора отключения.
  static Future<bool> disconnect({
    String? reason,
    String? source,
    String? connectionSessionId,
  }) async {
    if (!_supportsNativeVpnChannel) {
      return true;
    }
    try {
      final args = <String, dynamic>{};
      if (reason != null && reason.isNotEmpty) {
        args['reason'] = reason;
      }
      if (source != null && source.isNotEmpty) {
        args['source'] = source;
      }
      if (connectionSessionId != null && connectionSessionId.isNotEmpty) {
        args['connection_session_id'] = connectionSessionId;
      }
      final result = await _channel.invokeMethod<bool>('disconnect', args);
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('Ошибка отключения VPN: ${e.message}');
      throw VpnException('Ошибка отключения VPN: ${e.message}');
    } catch (e) {
      debugPrint('Неожиданная ошибка отключения VPN: $e');
      throw VpnException('Неожиданная ошибка: $e');
    }
  }

  /// Статус embedded AmneziaWG backend без старого GraniVpnService sync pipeline.
  static Future<bool?> getAmneziaWgStatus() async {
    if (!_supportsNativeVpnChannel) return false;
    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('getAmneziaWgStatus');
      final c = result?['connected'];
      if (c is bool) return c;
      return null;
    } on PlatformException catch (e) {
      debugPrint('Ошибка получения статуса AmneziaWG: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('Неожиданная ошибка получения статуса AmneziaWG: $e');
      return null;
    }
  }

  /// Статус туннеля с нативного слоя.
  ///
  /// `null` — не удалось опросить (ошибка канала, неверный ответ). **Не** эквивалент «VPN выключен»:
  /// для сверки UI с нативом используйте это и не сбрасывайте «подключено» при `null`.
  static Future<bool?> getNativeConnectionStatus() async {
    if (!_supportsNativeVpnChannel) return false;
    try {
      _getStatusCallCount++;
      final result =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('getStatus');
      final c = result?['connected'];
      if (c is bool) return c;
      return null;
    } on PlatformException catch (e) {
      debugPrint('Ошибка получения статуса VPN: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('Неожиданная ошибка получения статуса VPN: $e');
      return null;
    }
  }

  /// Получение статуса VPN подключения (ошибка опроса → `false` — только для обратной совместимости).
  static Future<bool> getStatus() async {
    return (await getNativeConnectionStatus()) ?? false;
  }

  /// Получение статистики трафика VPN
  /// Возвращает Map с ключами "rx_bytes" (входящий трафик) и "tx_bytes" (исходящий трафик)
  static Future<Map<String, int>> getTrafficStats() async {
    if (!_supportsNativeVpnChannel) {
      return {'rx_bytes': 0, 'tx_bytes': 0};
    }
    try {
      _getTrafficStatsCallCount++;
      final result =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('getTrafficStats');
      if (result != null) {
        return {
          'rx_bytes': (result['rx_bytes'] as num?)?.toInt() ?? 0,
          'tx_bytes': (result['tx_bytes'] as num?)?.toInt() ?? 0,
        };
      }
      return {'rx_bytes': 0, 'tx_bytes': 0};
    } on PlatformException catch (e) {
      debugPrint('Ошибка получения статистики трафика VPN: ${e.message}');
      return {'rx_bytes': 0, 'tx_bytes': 0};
    } catch (e) {
      debugPrint('Неожиданная ошибка получения статистики трафика VPN: $e');
      return {'rx_bytes': 0, 'tx_bytes': 0};
    }
  }

  /// Последний effective outbounds, рассчитанный нативным Xray routing (Android).
  static Future<String?> getEffectiveOutbounds() async {
    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('getEffectiveOutbounds');
      final v = result?['effective_outbounds'];
      if (v == null) return null;
      final s = v.toString().trim();
      return s.isEmpty ? null : s;
    } on PlatformException catch (e) {
      debugPrint('Ошибка получения effective outbounds: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('Неожиданная ошибка получения effective outbounds: $e');
      return null;
    }
  }

  /// Android: временно привязать процесс к сети без VPN (NOT_VPN), чтобы HTTP к API
  /// (например ожидание apply-state) не шёл через туннель в момент reload Xray на ноде.
  /// Пара [unbindUnderlyingNetworkForControlPlane] обязателен в `finally`.
  static Future<bool> bindUnderlyingNetworkForControlPlane() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      final m = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'bindUnderlyingNetworkForControlPlane',
      );
      return m != null && m['bound'] == true;
    } catch (e) {
      debugPrint('NativeVpnService.bindUnderlyingNetworkForControlPlane: $e');
      return false;
    }
  }

  static Future<void> unbindUnderlyingNetworkForControlPlane() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel
          .invokeMethod<void>('unbindUnderlyingNetworkForControlPlane');
    } catch (e) {
      debugPrint('NativeVpnService.unbindUnderlyingNetworkForControlPlane: $e');
    }
  }

  /// Android: нативный интервал тиков трафика (1 с в foreground, 4 с в background). Вне Android — no-op.
  static Future<void> setVpnTrafficTelemetryBackgroundMode(
      bool background) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>(
        'setTelemetryTrafficInterval',
        <String, dynamic>{'background': background},
      );
    } catch (e) {
      debugPrint('NativeVpnService.setVpnTrafficTelemetryBackgroundMode: $e');
    }
  }

  /// Проверка доступности Xray на устройстве (Android)
  static Future<bool> isXrayAvailable() async {
    if (!_isAndroidNativeVpn) return false;
    try {
      final result = await _channel.invokeMethod<bool>('isXrayAvailable');
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('Ошибка проверки доступности Xray: ${e.message}');
      return false;
    } catch (e) {
      debugPrint('Неожиданная ошибка проверки доступности Xray: $e');
      return false;
    }
  }

  /// Проверка, исключено ли приложение из оптимизации батареи (Android).
  /// Для стабильной работы VPN в фоне рекомендуется запросить исключение через [requestIgnoreBatteryOptimizations].
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!_isAndroidNativeVpn) return true;
    try {
      final result =
          await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint(
          'NativeVpnService: isIgnoringBatteryOptimizations: ${e.message}');
      return false;
    } catch (e) {
      debugPrint('NativeVpnService: isIgnoringBatteryOptimizations: $e');
      return false;
    }
  }

  /// Открывает системный экран запроса исключения из оптимизации батареи (Android).
  /// Возвращает true если уже исключено, false если открыт диалог или платформа не поддерживается.
  /// Опционально вызывать при первом подключении VPN или из настроек.
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!_isAndroidNativeVpn) return false;
    try {
      final result = await _channel
          .invokeMethod<bool>('requestIgnoreBatteryOptimizations');
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint(
          'NativeVpnService: requestIgnoreBatteryOptimizations: ${e.message}');
      return false;
    } catch (e) {
      debugPrint('NativeVpnService: requestIgnoreBatteryOptimizations: $e');
      return false;
    }
  }

  static const String splitTunnelModeExclude = 'exclude';
  static const String splitTunnelModeInclude = 'include';

  /// Режим split tunnel: exclude (выбранные в обход) или include (только выбранные используют VPN)
  static Future<String> getSplitTunnelMode() async {
    try {
      final result = await _channel.invokeMethod<String>('getSplitTunnelMode');
      return result ?? splitTunnelModeExclude;
    } on PlatformException catch (e) {
      debugPrint('NativeVpnService: getSplitTunnelMode: ${e.message}');
      return splitTunnelModeExclude;
    } catch (e) {
      debugPrint('NativeVpnService: getSplitTunnelMode: $e');
      return splitTunnelModeExclude;
    }
  }

  static Future<void> setSplitTunnelMode(String mode) async {
    try {
      await _channel.invokeMethod<void>(
          'setSplitTunnelMode', <String, dynamic>{'mode': mode});
    } on PlatformException catch (e) {
      debugPrint('NativeVpnService: setSplitTunnelMode: ${e.message}');
    } catch (e) {
      debugPrint('NativeVpnService: setSplitTunnelMode: $e');
    }
  }

  /// Список выбранных приложений для split tunnel
  static Future<List<String>> getSplitTunnelExcludedApps() async {
    try {
      final result = await _channel
          .invokeMethod<List<dynamic>>('getSplitTunnelExcludedApps');
      return result?.map((e) => e.toString()).toList() ?? [];
    } on PlatformException catch (e) {
      debugPrint('NativeVpnService: getSplitTunnelExcludedApps: ${e.message}');
      return [];
    } catch (e) {
      debugPrint('NativeVpnService: getSplitTunnelExcludedApps: $e');
      return [];
    }
  }

  /// Сохранить список приложений, исключённых из VPN
  static Future<void> setSplitTunnelExcludedApps(List<String> packages) async {
    try {
      await _channel.invokeMethod<void>('setSplitTunnelExcludedApps', packages);
    } on PlatformException catch (e) {
      debugPrint('NativeVpnService: setSplitTunnelExcludedApps: ${e.message}');
    } catch (e) {
      debugPrint('NativeVpnService: setSplitTunnelExcludedApps: $e');
    }
  }

  /// Домены для direct (обход VPN)
  static Future<List<String>> getSplitTunnelDirectDomains() async {
    try {
      final result = await _channel
          .invokeMethod<List<dynamic>>('getSplitTunnelDirectDomains');
      return result?.map((e) => e.toString()).toList() ?? [];
    } on PlatformException catch (e) {
      debugPrint('NativeVpnService: getSplitTunnelDirectDomains: ${e.message}');
      return [];
    } catch (e) {
      debugPrint('NativeVpnService: getSplitTunnelDirectDomains: $e');
      return [];
    }
  }

  static Future<void> setSplitTunnelDirectDomains(List<String> domains) async {
    try {
      await _channel.invokeMethod<void>('setSplitTunnelDirectDomains', domains);
    } on PlatformException catch (e) {
      debugPrint('NativeVpnService: setSplitTunnelDirectDomains: ${e.message}');
    } catch (e) {
      debugPrint('NativeVpnService: setSplitTunnelDirectDomains: $e');
    }
  }

  static const String dnsPolicyPerformance = 'performance';
  static const String dnsPolicyStrict = 'strict';

  static Future<String> getDnsPolicyMode() async {
    try {
      final r = await _channel.invokeMethod<String>('getDnsPolicyMode');
      return r ?? dnsPolicyPerformance;
    } on PlatformException catch (e) {
      debugPrint('NativeVpnService: getDnsPolicyMode: ${e.message}');
      return dnsPolicyPerformance;
    }
  }

  static Future<void> setDnsPolicyMode(String mode) async {
    try {
      await _channel.invokeMethod<void>(
          'setDnsPolicyMode', <String, dynamic>{'mode': mode});
    } on PlatformException catch (e) {
      debugPrint('NativeVpnService: setDnsPolicyMode: ${e.message}');
    }
  }

  /// Обновить routing в libXray по текущим prefs (DNS, split domains) без stop/start туннеля.
  static Future<bool> applyVpnRoutingHotSwap() async {
    try {
      final r = await _channel.invokeMethod<bool>('applyVpnRoutingHotSwap');
      return r ?? false;
    } on PlatformException catch (e) {
      debugPrint('NativeVpnService: applyVpnRoutingHotSwap: ${e.message}');
      return false;
    }
  }

  /// HTTP(S) через локальный SOCKS Xray (127.0.0.1:10808), если direct к API недоступен.
  static Future<Map<dynamic, dynamic>> apiRequestViaLocalSocks({
    required String url,
    required String method,
    Map<String, String>? headers,
    String? body,
  }) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'apiRequestViaLocalSocks',
      <String, dynamic>{
        'url': url,
        'method': method,
        'headers': headers ?? <String, String>{},
        if (body != null) 'body': body,
      },
    );
    if (result == null) {
      throw StateError('apiRequestViaLocalSocks: null response');
    }
    return result;
  }

  static Future<void> circuitBreakerRecordHealthSuccess() async {
    try {
      await _channel.invokeMethod<void>('circuitBreakerRecordHealthSuccess');
    } on PlatformException catch (_) {}
  }

  static Future<void> circuitBreakerRecordHealthFailure() async {
    try {
      await _channel.invokeMethod<void>('circuitBreakerRecordHealthFailure');
    } on PlatformException catch (_) {}
  }

  static Future<void> circuitBreakerRecordTransportReset() async {
    try {
      await _channel.invokeMethod<void>('circuitBreakerRecordTransportReset');
    } on PlatformException catch (_) {}
  }

  static Future<bool> isCircuitBreakerOpen() async {
    try {
      final r = await _channel.invokeMethod<bool>('isCircuitBreakerOpen');
      return r ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  /// Список установленных приложений для выбора (package, label)
  static Future<List<Map<String, String>>> getInstalledApps() async {
    try {
      final result =
          await _channel.invokeMethod<List<dynamic>>('getInstalledApps');
      if (result == null) return [];
      final list = <Map<String, String>>[];
      for (final e in result) {
        if (e is Map) {
          list.add(Map<String, String>.from(
              e.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''))));
        }
      }
      return list;
    } on PlatformException catch (e) {
      debugPrint('NativeVpnService: getInstalledApps: ${e.message}');
      return [];
    } catch (e) {
      debugPrint('NativeVpnService: getInstalledApps: $e');
      return [];
    }
  }

  /// Разрешить/запретить подключение с плитки быстрых настроек (по подписке/триалу)
  static Future<void> setAllowTileConnect(bool allow) async {
    try {
      await _channel.invokeMethod<void>(
          'setAllowTileConnect', <String, dynamic>{'allow': allow});
    } on PlatformException catch (e) {
      debugPrint('NativeVpnService: setAllowTileConnect: ${e.message}');
    } catch (e) {
      debugPrint('NativeVpnService: setAllowTileConnect: $e');
    }
  }

  /// Забрать одноразовое действие из Quick Settings tile.
  /// Сейчас поддерживается `toggle`: точный дубль основной кнопки подключения.
  static Future<String?> takeQuickTileAction() async {
    try {
      final action = await _channel.invokeMethod<String>('takeQuickTileAction');
      final normalized = action?.trim();
      return normalized == null || normalized.isEmpty ? null : normalized;
    } on PlatformException catch (e) {
      debugPrint('NativeVpnService: takeQuickTileAction: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('NativeVpnService: takeQuickTileAction: $e');
      return null;
    }
  }

  /// Запрос разрешения VPN у пользователя
  /// Возвращает true если разрешение уже есть или получено, false если отклонено
  static Future<bool> requestVpnPermission() async {
    if (!_supportsNativeVpnChannel) {
      throw _unsupportedPlatformException();
    }
    try {
      debugPrint('NativeVpnService: Запрос разрешения VPN');
      final result = await _channel.invokeMethod<bool>('requestPermission');
      debugPrint('NativeVpnService: Результат запроса разрешения: $result');
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('Ошибка запроса разрешения VPN: ${e.message}');
      if (e.code == 'PERMISSION_DENIED') {
        // Получаем понятное сообщение для пользователя из details
        final userMessage = e.details is Map
            ? (e.details as Map)['userMessage'] as String?
            : null;
        throw VpnPermissionException(userMessage ??
            'VPN разрешение отклонено. Для работы VPN необходимо предоставить разрешение в настройках системы.');
      }
      return false;
    } catch (e) {
      debugPrint('Неожиданная ошибка запроса разрешения VPN: $e');
      if (e is VpnPermissionException) {
        rethrow;
      }
      return false;
    }
  }
}

class VpnException implements Exception {
  final String message;
  VpnException(this.message);

  @override
  String toString() => 'VpnException: $message';
}

class VpnPermissionException extends VpnException {
  VpnPermissionException(String message) : super(message);
}

class VpnUnsupportedPlatformException extends VpnException {
  VpnUnsupportedPlatformException(String message) : super(message);
}

class DeviceLimitException extends VpnException {
  final int? limit;
  final int? currentCount;
  final List<dynamic> devices;

  DeviceLimitException(
    String message, {
    this.limit,
    this.currentCount,
    this.devices = const [],
  }) : super(message);
}

/// Нативный слой отклонил подключение: [runtime_contract.has_mismatch] (см. VpnPlugin.kt).
class ConfigMismatchException extends VpnException {
  ConfigMismatchException(
    String message, {
    this.correlationId,
    this.mismatchFields = const [],
  }) : super(message);

  final String? correlationId;
  final List<String> mismatchFields;
}

// ignore_for_file: prefer_single_quotes
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/cache/cache_service.dart';
import '../core/perf/perf_logger.dart';
import '../protocols/xray/models/xray_config.dart';
import '../services/native_vpn_service.dart';
import '../services/analytics_service.dart';
import 'simple_vpn_api.dart';
import 'simple_vpn_options_cache.dart';
import 'windows_hysteria2_config.dart';
import 'windows_vless_config.dart';

enum SimpleVpnState {
  disconnected,
  connecting,
  connected,
  disconnecting,
  error,
}

class _SimpleVpnConnectCancelled implements Exception {
  const _SimpleVpnConnectCancelled();
}

abstract class SimpleVpnRuntime {
  Future<bool> requestPermission();

  Future<bool> startConfig(
    SimpleVpnConfig config, {
    required String? sessionId,
    required String source,
  });

  Future<bool?> getAmneziaWgStatus();

  Future<bool?> getNativeConnectionStatus();

  Future<bool> disconnect({
    required String reason,
    required String source,
    required String? sessionId,
    bool includeLegacy = false,
  });
}

class AndroidSimpleVpnRuntime implements SimpleVpnRuntime {
  const AndroidSimpleVpnRuntime();

  @override
  Future<bool> requestPermission() {
    return NativeVpnService.requestPermission();
  }

  @override
  Future<bool> startConfig(
    SimpleVpnConfig config, {
    required String? sessionId,
    required String source,
  }) async {
    if (config.engine == 'amneziawg' || config.configType == 'amneziawg') {
      return NativeVpnService.connectAmneziaWg(
        config.config,
        connectionSessionId: sessionId,
        source: source,
      );
    }
    if (config.engine == 'xray') {
      final nativeConfig =
          XrayConfig.fromJson(config.jsonConfig).toXrayNativeJsonConfig();
      return NativeVpnService.connect(
        nativeConfig,
        protocol: config.protocol,
        connectionSessionId: sessionId,
        source: source,
      );
    }
    if (config.engine == 'hysteria2' || config.configType == 'hysteria2') {
      return NativeVpnService.connect(
        config.config,
        protocol: config.protocol,
        connectionSessionId: sessionId,
        source: source,
      );
    }
    throw Exception(
        'VPN engine ${config.engine} is not implemented in this build');
  }

  @override
  Future<bool?> getAmneziaWgStatus() {
    return NativeVpnService.getAmneziaWgStatus();
  }

  @override
  Future<bool?> getNativeConnectionStatus() {
    return NativeVpnService.getNativeConnectionStatus();
  }

  @override
  Future<bool> disconnect({
    required String reason,
    required String source,
    required String? sessionId,
    bool includeLegacy = false,
  }) async {
    final nativeActive =
        await NativeVpnService.getNativeConnectionStatus().catchError(
      (_) => false,
    );
    final amneziaWgActive =
        await NativeVpnService.getAmneziaWgStatus().catchError(
      (_) => false,
    );

    var stopped = false;
    if (nativeActive == true && amneziaWgActive != true) {
      stopped = await NativeVpnService.disconnect(
        reason: reason,
        source: source,
        connectionSessionId: sessionId,
      ).catchError((_) => false);
    } else {
      stopped = await NativeVpnService.disconnectAmneziaWg(
        reason: reason,
        source: source,
        connectionSessionId: sessionId,
      ).catchError((_) => false);
    }

    if (includeLegacy && !stopped) {
      final fallbackStopped = nativeActive == true && amneziaWgActive != true
          ? await NativeVpnService.disconnectAmneziaWg(
              reason: reason,
              source: source,
              connectionSessionId: sessionId,
            ).catchError((_) => false)
          : await NativeVpnService.disconnect(
              reason: reason,
              source: source,
              connectionSessionId: sessionId,
            ).catchError((_) => false);
      stopped = stopped || fallbackStopped;
    }
    return stopped;
  }
}

class UnsupportedSimpleVpnRuntime implements SimpleVpnRuntime {
  const UnsupportedSimpleVpnRuntime();

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<bool> startConfig(
    SimpleVpnConfig config, {
    required String? sessionId,
    required String source,
  }) async {
    throw VpnUnsupportedPlatformException(
      'GRANI VPN desktop tunnel is not implemented yet for '
      '${defaultTargetPlatform.name}.',
    );
  }

  @override
  Future<bool?> getAmneziaWgStatus() async => false;

  @override
  Future<bool?> getNativeConnectionStatus() async => false;

  @override
  Future<bool> disconnect({
    required String reason,
    required String source,
    required String? sessionId,
    bool includeLegacy = false,
  }) async {
    return true;
  }
}

class WindowsSimpleVpnRuntime implements SimpleVpnRuntime {
  const WindowsSimpleVpnRuntime();

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<bool> startConfig(
    SimpleVpnConfig config, {
    required String? sessionId,
    required String source,
  }) async {
    if (config.engine == 'xray' || config.protocol == 'vless_ws') {
      final nativeConfig = buildWindowsVlessConfig(config);
      return NativeVpnService.connectVless(
        nativeConfig,
        connectionSessionId: sessionId,
        source: source,
      );
    }
    if (config.engine == 'hysteria2' || config.protocol == 'hysteria2') {
      final nativeConfig = buildWindowsHysteria2Config(config);
      return NativeVpnService.connectHysteria2(
        nativeConfig,
        connectionSessionId: sessionId,
        source: source,
      );
    }
    if (config.engine == 'amneziawg' || config.configType == 'amneziawg') {
      return NativeVpnService.connectAmneziaWg(
        config.config,
        connectionSessionId: sessionId,
        source: source,
      );
    }
    throw VpnUnsupportedPlatformException(
      'VPN engine ${config.engine} is not supported by Windows runtime',
    );
  }

  @override
  Future<bool?> getAmneziaWgStatus() {
    return NativeVpnService.getNativeConnectionStatus();
  }

  @override
  Future<bool?> getNativeConnectionStatus() {
    return NativeVpnService.getNativeConnectionStatus();
  }

  @override
  Future<bool> disconnect({
    required String reason,
    required String source,
    required String? sessionId,
    bool includeLegacy = false,
  }) {
    return NativeVpnService.disconnect(
      reason: reason,
      source: source,
      connectionSessionId: sessionId,
    );
  }
}

class MacOSSimpleVpnRuntime implements SimpleVpnRuntime {
  const MacOSSimpleVpnRuntime();

  @override
  Future<bool> requestPermission() => NativeVpnService.requestPermission();

  @override
  Future<bool> startConfig(
    SimpleVpnConfig config, {
    required String? sessionId,
    required String source,
  }) {
    if (config.engine != 'amneziawg' && config.configType != 'amneziawg') {
      throw VpnUnsupportedPlatformException(
        'Only GRANIwg/AmneziaWG is supported by the macOS runtime.',
      );
    }
    return NativeVpnService.connectAmneziaWg(
      config.config,
      connectionSessionId: sessionId,
      source: source,
    );
  }

  @override
  Future<bool?> getAmneziaWgStatus() {
    return NativeVpnService.getAmneziaWgStatus();
  }

  @override
  Future<bool?> getNativeConnectionStatus() {
    return NativeVpnService.getNativeConnectionStatus();
  }

  @override
  Future<bool> disconnect({
    required String reason,
    required String source,
    required String? sessionId,
    bool includeLegacy = false,
  }) {
    return NativeVpnService.disconnectAmneziaWg(
      reason: reason,
      source: source,
      connectionSessionId: sessionId,
    );
  }
}

SimpleVpnRuntime createSimpleVpnRuntime() {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return const AndroidSimpleVpnRuntime();
  }
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    return const WindowsSimpleVpnRuntime();
  }
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
    return const MacOSSimpleVpnRuntime();
  }
  return const UnsupportedSimpleVpnRuntime();
}

class SimpleVpnController extends ChangeNotifier {
  SimpleVpnController({
    SimpleVpnApi? api,
    SimpleVpnRuntime? runtime,
    Future<String?> Function()? deviceIdProvider,
    Future<void> Function()? ensureDeviceRegistered,
    void Function(DeviceLimitException error)? onDeviceLimit,
  })  : _api = api ?? SimpleVpnApi(),
        _runtime = runtime ?? createSimpleVpnRuntime(),
        _deviceIdProvider = deviceIdProvider,
        _ensureDeviceRegistered = ensureDeviceRegistered,
        _onDeviceLimit = onDeviceLimit {
    if (_runtime is WindowsSimpleVpnRuntime) {
      _selectedProtocol = _protocols.firstWhere(
        (protocol) => protocol.id == 'graniwg',
        orElse: () => _selectedProtocol,
      );
    }
    _normalizeProtocolsForRuntime();
    _startNativeStateSubscription();
  }

  static const Duration _configCacheTtl = Duration(days: 7);
  static const String _activeSessionCacheKey =
      "simple_vpn_active_session_id_v1";
  static const String _activeRuntimeSessionCacheKey =
      "simple_vpn_active_runtime_session_id_v1";
  static const String _selectedServerCacheKey =
      "simple_vpn_selected_server_id_v1";
  static const String _selectedProtocolCacheKey =
      "simple_vpn_selected_protocol_id_v1";
  static const String _optionsCacheKey = simpleVpnOptionsCacheKey;
  static const String _runtimeSessionPrefix = "local_runtime_";
  static const Duration _optionsCacheTtl = simpleVpnOptionsCacheTtl;
  static const List<Duration> _sessionStartRetryDelays = <Duration>[
    Duration(milliseconds: 900),
    Duration(milliseconds: 1600),
  ];
  static const List<Duration> _configFetchRetryDelays = <Duration>[
    Duration(milliseconds: 900),
    Duration(milliseconds: 1800),
  ];
  static const Duration _disconnectBarrierTimeout = Duration(seconds: 6);
  static const Duration _runtimeDownPollInterval = Duration(milliseconds: 220);
  static const Duration _runtimeDownStatusTimeout = Duration(milliseconds: 500);

  final SimpleVpnApi _api;
  final SimpleVpnRuntime _runtime;
  final CacheService _cacheService = CacheService();
  final AnalyticsService _analyticsService = AnalyticsService();
  final Future<String?> Function()? _deviceIdProvider;
  final Future<void> Function()? _ensureDeviceRegistered;
  final void Function(DeviceLimitException error)? _onDeviceLimit;
  Future<void>? _selectedConfigWarmup;
  String? _selectedConfigWarmupKey;

  SimpleVpnState _state = SimpleVpnState.disconnected;
  String? _sessionId;
  String? _serverName;
  String? _error;
  bool _disposed = false;
  bool _optionsLoading = false;
  SimpleVpnConfig? _lastConnectedConfig;
  String? _lastConnectedDeviceId;
  bool _lastConnectedConfigFromCache = false;
  bool _nodeVerificationInFlight = false;
  bool _nodeTrafficVerifiedForSession = false;
  int _connectAttemptId = 0;
  int _disconnectOperationId = 0;
  int _uiStateTraceSeq = 0;
  bool _connectCancelRequested = false;
  Future<void>? _disconnectInFlight;
  String? _activeConnectSessionId;
  String? _activeConnectDeviceId;
  String? _runtimeSessionId;
  Timer? _connectProgressTimer;
  Timer? _entitlementTimer;
  StreamSubscription<Map<dynamic, dynamic>>? _nativeStateSubscription;
  bool _accessRequired = false;
  int _longConnectMessageIndex = 0;
  String? _connectionProgressText;
  String? _connectionModeBadge;
  int? _connectionProgressPercent;
  List<SimpleVpnServer> _servers = <SimpleVpnServer>[];
  List<SimpleVpnProtocol> _protocols = <SimpleVpnProtocol>[
    SimpleVpnProtocol(
        id: 'vless_ws', engine: 'xray', status: 'planned', role: 'fallback'),
    SimpleVpnProtocol(
        id: 'hysteria2',
        engine: 'hysteria2',
        status: 'planned',
        role: 'fallback'),
    SimpleVpnProtocol(
        id: 'graniwg', engine: 'amneziawg', status: 'active', role: 'primary'),
  ];
  SimpleVpnServer? _selectedServer;
  SimpleVpnProtocol _selectedProtocol = SimpleVpnProtocol(
    id: 'vless_ws',
    engine: 'xray',
    status: 'active',
    role: 'primary',
  );

  SimpleVpnState get state => _state;
  String? get sessionId => _sessionId;
  String get serverName => _serverName ?? _selectedServer?.name ?? 'GRANI VPN';
  String? get error => _error;
  String? get connectionProgressText => _connectionProgressText;
  String? get connectionModeBadge => _connectionModeBadge;
  int? get connectionProgressPercent => _connectionProgressPercent;
  bool get isBusy =>
      _state == SimpleVpnState.connecting ||
      _state == SimpleVpnState.disconnecting;
  bool get isConnecting => _state == SimpleVpnState.connecting;
  bool get isConnected => _state == SimpleVpnState.connected;
  bool get optionsLoading => _optionsLoading;
  bool get accessRequired => _accessRequired;
  List<SimpleVpnServer> get servers => List.unmodifiable(_servers);
  List<SimpleVpnProtocol> get protocols => List.unmodifiable(_protocols);
  SimpleVpnServer? get selectedServer => _selectedServer;
  SimpleVpnProtocol get selectedProtocol => _selectedProtocol;

  static const List<String> _longConnectMessages = <String>[
    'Подключение занимает чуть больше времени.',
    'Пробуем другой маршрут подключения...',
    'Восстановление может занять чуть дольше.',
    'Медленная сеть. Продолжаем подключение...',
    'Пробуем оптимизировать маршрут...',
    'Настройка может занять до минуты.',
  ];

  void _startConnectProgressTimer() {
    _connectProgressTimer?.cancel();
    _longConnectMessageIndex = 0;
    _connectProgressTimer =
        Timer.periodic(const Duration(seconds: 12), (timer) {
      if (_disposed || _state != SimpleVpnState.connecting) {
        timer.cancel();
        return;
      }
      final message = _longConnectMessages[
          _longConnectMessageIndex % _longConnectMessages.length];
      _longConnectMessageIndex++;
      _setConnectionProgress(message);
    });
  }

  void _stopConnectProgressTimer() {
    _connectProgressTimer?.cancel();
    _connectProgressTimer = null;
    _longConnectMessageIndex = 0;
  }

  String _createRuntimeOnlySessionId({
    required int attemptId,
    required String protocol,
  }) {
    final safeProtocol = protocol.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_');
    return '$_runtimeSessionPrefix${safeProtocol}_${attemptId}_${DateTime.now().microsecondsSinceEpoch}';
  }

  bool _isRuntimeOnlySessionId(String? sessionId) {
    return sessionId != null && sessionId.startsWith(_runtimeSessionPrefix);
  }

  String? _currentNativeRuntimeSessionId() {
    final runtime = _runtimeSessionId?.trim();
    if (runtime != null && runtime.isNotEmpty) return runtime;

    final active = _activeConnectSessionId?.trim();
    if (_isRuntimeOnlySessionId(active)) return active;

    return null;
  }

  String? _backendSessionId(String? sessionId) {
    if (sessionId == null || sessionId.isEmpty) return null;
    return _isRuntimeOnlySessionId(sessionId) ? null : sessionId;
  }

  bool _canStartLocalConfigFastPath({
    required String? deviceId,
  }) {
    return !_accessRequired &&
        !_connectCancelRequested &&
        deviceId != null &&
        deviceId.isNotEmpty;
  }

  void _startEntitlementTimer() {
    _entitlementTimer?.cancel();
    _entitlementTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      unawaited(_checkEntitlementWhileConnected(source: 'periodic'));
    });
  }

  void _stopEntitlementTimer() {
    _entitlementTimer?.cancel();
    _entitlementTimer = null;
  }

  void _setConnectionProgress(
    String? text, {
    int? percent,
    String? badge,
  }) {
    _connectionProgressText = text;
    if (percent != null) {
      _connectionProgressPercent = percent.clamp(0, 100);
    }
    if (badge != null) {
      _connectionModeBadge = badge;
    }
    _notify();
  }

  void _clearConnectionProgress() {
    _connectionProgressText = null;
    _connectionModeBadge = null;
    _connectionProgressPercent = null;
    _stopConnectProgressTimer();
  }

  Future<String?> _resolveDeviceId({bool ensureRegistered = false}) async {
    if (ensureRegistered) {
      await _ensureDeviceRegistered?.call();
    }
    final deviceId = (await _deviceIdProvider?.call())?.trim();
    return deviceId == null || deviceId.isEmpty ? null : deviceId;
  }

  Future<void> loadOptions() async {
    if (_optionsLoading) return;
    final perf = PerfLogger();
    perf.start('simple_vpn_load_options_total');
    final cachedServerId = await _readSelectedServerId();
    final cachedProtocolId = await _readSelectedProtocolId();
    final loadedFromCache =
        await _loadCachedOptions(cachedServerId, cachedProtocolId);
    final hydratedFromConfig = loadedFromCache
        ? false
        : await _hydrateSelectionFromCachedConfig(
            preferredServerId: cachedServerId,
            preferredProtocolId: cachedProtocolId,
          );
    final hasLocalOptions = loadedFromCache || hydratedFromConfig;
    _optionsLoading = true;
    _notify();
    try {
      perf.start('simple_vpn_load_options_network');
      var results = await Future.wait<dynamic>([
        _api.fetchServers(),
        _api.fetchProtocols(),
      ]);
      var servers = results[0] as List<SimpleVpnServer>;
      var protocols = results[1] as List<SimpleVpnProtocol>;
      if (servers.isEmpty && !hasLocalOptions) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        results = await Future.wait<dynamic>([
          _api.fetchServers(),
          _api.fetchProtocols(),
        ]);
        servers = results[0] as List<SimpleVpnServer>;
        protocols = results[1] as List<SimpleVpnProtocol>;
      }
      if (servers.isEmpty && _servers.isNotEmpty) {
        perf.stop('simple_vpn_load_options_network', details: {
          'result': 'empty_servers_keep_cache',
        });
        _applyOptions(
          servers: _servers,
          protocols: protocols,
          preferredServerId: cachedServerId,
          preferredProtocolId: cachedProtocolId,
        );
        await _persistCachedOptions();
        unawaited(_warmSelectedConfigForFastPath(reason: 'load_options'));
        _error = null;
        return;
      }
      if (servers.isEmpty) {
        throw StateError('Список VPN-серверов пуст');
      }
      perf.stop('simple_vpn_load_options_network', details: {
        'result': 'success',
      });
      _applyOptions(
        servers: servers,
        protocols: protocols,
        preferredServerId: cachedServerId,
        preferredProtocolId: cachedProtocolId,
      );
      await _persistCachedOptions();
      unawaited(_warmSelectedConfigForFastPath(reason: 'load_options'));
      _error = null;
    } on SimpleVpnAccessRequiredException catch (e) {
      perf.stop('simple_vpn_load_options_network', details: {
        'result': 'access_required',
      });
      await _handleAccessRequired(source: 'load_options', message: e.message);
    } catch (e) {
      perf.stop('simple_vpn_load_options_network', details: {
        'result': 'error',
        'cache_used': hasLocalOptions,
        'error': e.toString(),
      });
      if (!hasLocalOptions) {
        _error = e.toString();
      }
    } finally {
      _optionsLoading = false;
      perf.stop('simple_vpn_load_options_total', details: {
        'cache_used': hasLocalOptions,
        'options_cache_used': loadedFromCache,
        'config_cache_used': hydratedFromConfig,
        'servers': _servers.length,
        'protocols': _protocols.length,
      });
      _notify();
    }
  }

  void _applyOptions({
    required List<SimpleVpnServer> servers,
    required List<SimpleVpnProtocol> protocols,
    required int? preferredServerId,
    required String? preferredProtocolId,
  }) {
    if (servers.isNotEmpty) {
      _servers = servers;
    }
    final runtimeProtocols = _filterProtocolsForRuntime(protocols);
    if (runtimeProtocols.isNotEmpty) {
      _protocols = runtimeProtocols;
    } else {
      _normalizeProtocolsForRuntime();
    }
    if (_servers.isNotEmpty) {
      final currentId = _selectedServer?.id ?? preferredServerId;
      _selectedServer = _servers.firstWhere(
        (server) => server.id == currentId,
        orElse: () => _servers.first,
      );
      unawaited(_persistSelectedServerId(_selectedServer!.id));
    }
    if (_protocols.isNotEmpty) {
      final fallbackProtocolId = _runtimeFallbackProtocolId();
      final preferredId = _isProtocolSupportedByRuntime(preferredProtocolId)
          ? preferredProtocolId
          : _isProtocolSupportedByRuntime(_selectedProtocol.id)
              ? _selectedProtocol.id
              : fallbackProtocolId;
      _selectedProtocol = _protocols.firstWhere(
        (protocol) => protocol.id == preferredId,
        orElse: () => _protocols.firstWhere(
          (protocol) => protocol.id == fallbackProtocolId,
        ),
      );
      unawaited(_persistSelectedProtocolId(_selectedProtocol.id));
    }
  }

  Future<bool> _loadCachedOptions(
      int? preferredServerId, String? preferredProtocolId) async {
    final raw = await _cacheService.getString(_optionsCacheKey);
    if (raw == null || raw.isEmpty) return false;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return false;
      final map = Map<String, dynamic>.from(decoded);
      final rawServers = map['servers'];
      final rawProtocols = map['protocols'];
      if (rawServers is! List) return false;
      final cachedServers = rawServers
          .whereType<Map>()
          .map((item) =>
              SimpleVpnServer.fromJson(Map<String, dynamic>.from(item)))
          .where((server) => server.id > 0)
          .toList(growable: false);
      final cachedProtocols = rawProtocols is List
          ? rawProtocols
              .whereType<Map>()
              .map((item) =>
                  SimpleVpnProtocol.fromJson(Map<String, dynamic>.from(item)))
              .where((protocol) =>
                  protocol.id == 'vless_ws' ||
                  protocol.id == 'hysteria2' ||
                  protocol.id == 'graniwg')
              .toList(growable: false)
          : <SimpleVpnProtocol>[];
      if (cachedServers.isEmpty) return false;
      _applyOptions(
        servers: cachedServers,
        protocols: cachedProtocols,
        preferredServerId: preferredServerId,
        preferredProtocolId: preferredProtocolId,
      );
      _error = null;
      _notify();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _hydrateSelectionFromCachedConfig({
    required int? preferredServerId,
    required String? preferredProtocolId,
  }) async {
    final deviceId = await _resolveDeviceId(ensureRegistered: false);
    final protocolCandidates = <String>[];
    void addProtocol(String? id) {
      if (_isProtocolSupportedByRuntime(id) &&
          !protocolCandidates.contains(id)) {
        protocolCandidates.add(id!);
      }
    }

    addProtocol(preferredProtocolId);
    addProtocol(_selectedProtocol.id);
    addProtocol('graniwg');
    addProtocol('vless_ws');
    addProtocol('hysteria2');

    final serverCandidates = <int?>[];
    void addServerId(int? id) {
      if (serverCandidates.contains(id)) return;
      serverCandidates.add(id);
    }

    addServerId(preferredServerId);
    addServerId(_selectedServer?.id);
    addServerId(null);

    final deviceCandidates = <String?>[];
    void addDeviceId(String? id) {
      final value = id?.trim();
      final normalized = value == null || value.isEmpty ? null : value;
      if (deviceCandidates.contains(normalized)) return;
      deviceCandidates.add(normalized);
    }

    addDeviceId(deviceId);
    addDeviceId(null);

    for (final protocolId in protocolCandidates) {
      for (final candidateDeviceId in deviceCandidates) {
        for (final candidateServerId in serverCandidates) {
          final config = await _readCachedConfig(
            serverId: candidateServerId,
            protocol: protocolId,
            deviceId: candidateDeviceId,
          );
          final cachedConfig = config;
          if (cachedConfig == null) continue;
          final server = cachedConfig.server;
          if (server == null || server.id <= 0) continue;

          if (_servers.every((item) => item.id != server.id)) {
            _servers = _servers.isEmpty
                ? <SimpleVpnServer>[server]
                : <SimpleVpnServer>[..._servers, server];
          }
          _selectedServer = _servers.firstWhere(
            (item) => item.id == server.id,
            orElse: () => server,
          );
          _serverName = cachedConfig.serverName;
          _selectedProtocol = _protocols.firstWhere(
            (protocol) => protocol.id == cachedConfig.protocol,
            orElse: () => SimpleVpnProtocol(
              id: cachedConfig.protocol,
              engine: cachedConfig.engine,
              status: 'active',
              role: 'cached_config',
            ),
          );
          _error = null;
          unawaited(_persistSelectedServerId(server.id));
          unawaited(_persistSelectedProtocolId(cachedConfig.protocol));
          await _persistCachedOptions();
          debugPrint(
            'SimpleVpnController.options_hydrated_from_config '
            'server_id=${server.id} protocol=${cachedConfig.protocol} '
            'device_id=${candidateDeviceId ?? 'default'}',
          );
          _notify();
          return true;
        }
      }
    }
    return false;
  }

  Future<void> _persistCachedOptions() async {
    if (_servers.isEmpty) return;
    await _cacheService.setString(
      _optionsCacheKey,
      jsonEncode(
        buildSimpleVpnOptionsCachePayload(
          servers: _servers,
          protocols: _protocols,
        ),
      ),
      ttl: _optionsCacheTtl,
    );
  }

  Future<void> _warmSelectedConfigForFastPath({required String reason}) async {
    if (_disposed || _selectedServer == null) return;
    final protocol = _selectedProtocol.id;
    if (!_isProtocolSupportedByRuntime(protocol)) return;
    try {
      final deviceId = await _resolveDeviceId(ensureRegistered: false);
      if (deviceId == null || deviceId.isEmpty) return;
      await _warmConfigForFastPath(
        serverId: _selectedServer!.id,
        protocol: protocol,
        deviceId: deviceId,
        reason: reason,
      );
    } catch (e) {
      debugPrint('SimpleVpnController.config_warmup_skipped reason=$reason $e');
    }
  }

  Future<void> _warmConfigForFastPath({
    required int? serverId,
    required String protocol,
    required String deviceId,
    required String reason,
  }) {
    final key = _configCacheKey(
      serverId: serverId,
      protocol: protocol,
      deviceId: deviceId,
    );
    final existing = _selectedConfigWarmup;
    if (_selectedConfigWarmupKey == key && existing != null) {
      return existing;
    }
    final warmup = () async {
      final cached = await _readCachedConfig(
        serverId: serverId,
        protocol: protocol,
        deviceId: deviceId,
      );
      if (cached != null || _disposed) return;
      final config = await _fetchConfigWithRetry(
        serverId: serverId,
        deviceId: deviceId,
        protocol: protocol,
        attemptId: _connectAttemptId,
        source: 'config_warmup',
        reason: reason,
      );
      if (_disposed) return;
      await _writeCachedConfig(
        config,
        serverId: config.server?.id ?? serverId,
        deviceId: deviceId,
      );
      debugPrint(
        'SimpleVpnController.config_warmup_done '
        'reason=$reason server_id=${config.server?.id ?? serverId} '
        'protocol=${config.protocol}',
      );
    }()
        .catchError((Object e) {
      debugPrint('SimpleVpnController.config_warmup_failed reason=$reason $e');
    });
    _selectedConfigWarmupKey = key;
    _selectedConfigWarmup = warmup.whenComplete(() {
      if (_selectedConfigWarmupKey == key) {
        _selectedConfigWarmupKey = null;
        _selectedConfigWarmup = null;
      }
    });
    return _selectedConfigWarmup!;
  }

  Future<void> _awaitSelectedConfigWarmupIfMatching({
    required int? serverId,
    required String protocol,
    required String? deviceId,
    required int attemptId,
    required String source,
  }) async {
    if (deviceId == null || deviceId.isEmpty) return;
    final key = _configCacheKey(
      serverId: serverId,
      protocol: protocol,
      deviceId: deviceId,
    );
    final warmup =
        _selectedConfigWarmupKey == key ? _selectedConfigWarmup : null;
    if (warmup == null) return;
    _traceConnectPhase(
      'config_warmup_await',
      attemptId: attemptId,
      source: source,
      deviceId: deviceId,
      extra: <String, dynamic>{
        'server_id': serverId,
        'protocol': protocol,
      },
    );
    try {
      await warmup.timeout(const Duration(seconds: 2));
    } catch (e) {
      _traceConnectPhase(
        'config_warmup_await_timeout',
        attemptId: attemptId,
        source: source,
        deviceId: deviceId,
        extra: <String, dynamic>{'error': e.toString()},
      );
    }
  }

  void selectServer(SimpleVpnServer server) {
    if (isBusy || isConnected) return;
    if (_selectedServer?.id == server.id) return;
    _selectedServer = server;
    _serverName = server.name;
    _error = null;
    unawaited(_persistSelectedServerId(server.id));
    unawaited(_warmSelectedConfigForFastPath(reason: 'select_server'));
    _notify();
  }

  void selectProtocol(SimpleVpnProtocol protocol) {
    if (isBusy || isConnected) return;
    if (!_isProtocolSupportedByRuntime(protocol.id)) {
      return;
    }
    _selectedProtocol = protocol;
    _error = null;
    unawaited(_persistSelectedProtocolId(protocol.id));
    unawaited(_warmSelectedConfigForFastPath(reason: 'select_protocol'));
    _notify();
  }

  bool _isSupportedProtocolId(String? protocolId) {
    return protocolId == 'graniwg' ||
        protocolId == 'vless_ws' ||
        protocolId == 'hysteria2';
  }

  bool _isProtocolSupportedByRuntime(String? protocolId) {
    if (!_isSupportedProtocolId(protocolId)) return false;
    if (_runtime is WindowsSimpleVpnRuntime) {
      return protocolId == 'graniwg' ||
          protocolId == 'hysteria2' ||
          protocolId == 'vless_ws';
    }
    if (_runtime is MacOSSimpleVpnRuntime) {
      return protocolId == 'graniwg';
    }
    return true;
  }

  List<SimpleVpnProtocol> _filterProtocolsForRuntime(
    Iterable<SimpleVpnProtocol> protocols,
  ) {
    return protocols
        .where((protocol) => _isProtocolSupportedByRuntime(protocol.id))
        .toList(growable: false);
  }

  String _runtimeFallbackProtocolId() {
    if (_protocols.any((protocol) => protocol.id == 'graniwg')) {
      return 'graniwg';
    }
    return _protocols.first.id;
  }

  void _normalizeProtocolsForRuntime() {
    final runtimeProtocols = _filterProtocolsForRuntime(_protocols);
    if (runtimeProtocols.isNotEmpty) {
      _protocols = runtimeProtocols;
    }
    if (!_isProtocolSupportedByRuntime(_selectedProtocol.id) ||
        !_protocols.any((protocol) => protocol.id == _selectedProtocol.id)) {
      final fallbackProtocolId = _runtimeFallbackProtocolId();
      _selectedProtocol = _protocols.firstWhere(
        (protocol) => protocol.id == fallbackProtocolId,
      );
    }
  }

  Future<SimpleVpnStartResult?> _safeStartSession(
    String protocol,
    String? deviceId,
    int? serverId, {
    int? attemptId,
    String? source,
    SimpleVpnConfig? config,
  }) async {
    Object? lastError;
    final maxAttempts = 1 + _sessionStartRetryDelays.length;
    for (var index = 0; index < maxAttempts; index += 1) {
      final retryNumber = index + 1;
      try {
        final result = await _api.startSession(
            protocol: protocol, deviceId: deviceId, serverId: serverId);
        if (result.sessionId.isNotEmpty) {
          if (index > 0) {
            _traceConnectPhase(
              'session_start_retry_success',
              attemptId: attemptId,
              source: source,
              sessionId: result.sessionId,
              deviceId: deviceId,
              config: config,
              extra: <String, dynamic>{
                'retry_number': retryNumber,
                'max_attempts': maxAttempts,
              },
            );
          }
          return result;
        }
        lastError = 'empty_session_id';
      } on SimpleVpnAccessRequiredException {
        rethrow;
      } catch (error) {
        lastError = error;
      }

      if (index >= _sessionStartRetryDelays.length) break;
      final delay = _sessionStartRetryDelays[index];
      _traceConnectPhase(
        'session_start_retry_wait',
        attemptId: attemptId,
        source: source,
        deviceId: deviceId,
        config: config,
        extra: <String, dynamic>{
          'retry_number': retryNumber,
          'next_retry_number': retryNumber + 1,
          'max_attempts': maxAttempts,
          'delay_ms': delay.inMilliseconds,
          'reason': lastError.toString(),
        },
      );
      unawaited(_api.log(
        event: 'session_start_retry_wait',
        deviceId: deviceId,
        details: <String, dynamic>{
          'protocol': protocol,
          'server_id': serverId,
          'retry_number': retryNumber,
          'next_retry_number': retryNumber + 1,
          'max_attempts': maxAttempts,
          'delay_ms': delay.inMilliseconds,
          'reason': lastError.toString(),
          'source': source,
        },
      ));
      _setConnectionProgress(
        retryNumber == 1
            ? 'Сеть нестабильна. Подключаемся...'
            : 'Продолжаем подключение, ждём ответ сети...',
        percent: 54 + index * 2,
      );
      if (attemptId != null) _throwIfConnectCancelled(attemptId);
      await Future.delayed(delay);
      if (attemptId != null) _throwIfConnectCancelled(attemptId);
    }
    _traceConnectPhase(
      'session_start_retries_exhausted',
      attemptId: attemptId,
      source: source,
      deviceId: deviceId,
      config: config,
      extra: <String, dynamic>{
        'max_attempts': maxAttempts,
        'last_error': lastError?.toString(),
      },
    );
    return null;
  }

  Future<SimpleVpnStartResult?> _startSessionForCachedFastPath({
    required String protocol,
    required String? deviceId,
    required int? serverId,
    required int attemptId,
    required String source,
    required String runtimeSessionId,
    required SimpleVpnConfig config,
  }) async {
    Object? lastError;
    final maxAttempts = 1 + _sessionStartRetryDelays.length;
    for (var index = 0; index < maxAttempts; index += 1) {
      final retryNumber = index + 1;
      try {
        final result = await _api.startSession(
          protocol: protocol,
          deviceId: deviceId,
          serverId: serverId,
        );
        if (result.sessionId.isNotEmpty) return result;
        lastError = 'empty_session_id';
      } on SimpleVpnAccessRequiredException {
        rethrow;
      } catch (error) {
        lastError = error;
      }

      if (index >= _sessionStartRetryDelays.length) break;
      final delay = _sessionStartRetryDelays[index];
      _traceConnectPhase(
        'background_session_start_retry_wait',
        attemptId: attemptId,
        source: source,
        sessionId: runtimeSessionId,
        deviceId: deviceId,
        config: config,
        extra: <String, dynamic>{
          'retry_number': retryNumber,
          'next_retry_number': retryNumber + 1,
          'max_attempts': maxAttempts,
          'delay_ms': delay.inMilliseconds,
          'reason': lastError.toString(),
        },
      );
      await Future<void>.delayed(delay);
    }
    _traceConnectPhase(
      'background_session_start_retries_exhausted',
      attemptId: attemptId,
      source: source,
      sessionId: runtimeSessionId,
      deviceId: deviceId,
      config: config,
      extra: <String, dynamic>{
        'max_attempts': maxAttempts,
        'last_error': lastError?.toString(),
      },
    );
    return null;
  }

  Future<void> _startBackendSessionAfterCachedFastPath({
    required SimpleVpnConfig config,
    required String? deviceId,
    required String runtimeSessionId,
    required int attemptId,
    required String source,
  }) async {
    if (deviceId == null || deviceId.isEmpty) return;
    if (_disposed ||
        _state != SimpleVpnState.connected ||
        !_isCurrentRuntimeSession(runtimeSessionId)) {
      _traceConnectPhase(
        'background_session_start_stale_ignored',
        attemptId: attemptId,
        source: source,
        sessionId: runtimeSessionId,
        deviceId: deviceId,
        config: config,
        extra: <String, dynamic>{
          'current_attempt_id': _connectAttemptId,
          'ui_state': _state.name,
          'runtime_session_id': _runtimeSessionId,
        },
      );
      return;
    }
    final serverId = config.server?.id ?? _selectedServer?.id;
    _traceConnectPhase(
      'background_session_start_begin',
      attemptId: attemptId,
      source: source,
      sessionId: runtimeSessionId,
      deviceId: deviceId,
      config: config,
      extra: <String, dynamic>{
        'runtime_session_id': runtimeSessionId,
        'control_plane_mode': 'background',
      },
    );
    try {
      final start = await _startSessionForCachedFastPath(
        protocol: config.protocol,
        deviceId: deviceId,
        serverId: serverId,
        attemptId: attemptId,
        source: source,
        runtimeSessionId: runtimeSessionId,
        config: config,
      );
      final backendSessionId = start?.sessionId;
      if (backendSessionId == null || backendSessionId.isEmpty) {
        unawaited(_api.log(
          event: 'background_session_start_missing',
          level: 'warning',
          sessionId: runtimeSessionId,
          deviceId: deviceId,
          details: <String, dynamic>{
            'protocol': config.protocol,
            'server_id': serverId,
            'control_plane_mode': 'background',
          },
        ));
        return;
      }

      final stillCurrent = !_disposed &&
          _state == SimpleVpnState.connected &&
          _isCurrentRuntimeSession(runtimeSessionId);
      if (!stillCurrent) {
        await _api
            .stopSession(
              sessionId: backendSessionId,
              reason: 'fast_path_late_session_cleanup',
              deviceId: deviceId,
            )
            .catchError((_) {});
        _traceConnectPhase(
          'background_session_start_late_cleanup',
          attemptId: attemptId,
          source: source,
          sessionId: backendSessionId,
          deviceId: deviceId,
          config: config,
          extra: <String, dynamic>{
            'runtime_session_id': runtimeSessionId,
            'ui_state_after_start': _state.name,
          },
        );
        return;
      }

      _sessionId = backendSessionId;
      await _persistActiveSessionId(backendSessionId);
      _traceConnectPhase(
        'background_session_start_done',
        attemptId: attemptId,
        source: source,
        sessionId: backendSessionId,
        deviceId: deviceId,
        config: config,
        extra: <String, dynamic>{
          'runtime_session_id': runtimeSessionId,
          'control_plane_mode': 'background',
        },
      );
      unawaited(_api.log(
        event: 'background_session_start_done',
        sessionId: backendSessionId,
        deviceId: deviceId,
        details: <String, dynamic>{
          'runtime_session_id': runtimeSessionId,
          'protocol': config.protocol,
          'server_id': serverId,
          'source': source,
        },
      ));
      _scheduleNodeTrafficVerification();
    } on SimpleVpnAccessRequiredException catch (e) {
      if (_disposed ||
          _state != SimpleVpnState.connected ||
          !_isCurrentRuntimeSession(runtimeSessionId)) {
        _traceConnectPhase(
          'background_session_start_access_required_stale_ignored',
          attemptId: attemptId,
          source: source,
          sessionId: runtimeSessionId,
          deviceId: deviceId,
          config: config,
          extra: <String, dynamic>{
            'message': e.message,
            'current_attempt_id': _connectAttemptId,
            'ui_state': _state.name,
            'runtime_session_id': _runtimeSessionId,
          },
        );
        return;
      }
      _traceConnectPhase(
        'background_session_start_access_required',
        attemptId: attemptId,
        source: source,
        sessionId: runtimeSessionId,
        deviceId: deviceId,
        config: config,
        extra: <String, dynamic>{'message': e.message},
      );
      await _handleAccessRequired(
        source: 'background_session_start',
        message: e.message,
        sessionId: runtimeSessionId,
        deviceId: deviceId,
      );
    } on DeviceLimitException catch (e) {
      if (_disposed ||
          _state != SimpleVpnState.connected ||
          !_isCurrentRuntimeSession(runtimeSessionId)) {
        _traceConnectPhase(
          'background_session_start_device_limit_stale_ignored',
          attemptId: attemptId,
          source: source,
          sessionId: runtimeSessionId,
          deviceId: deviceId,
          config: config,
          extra: <String, dynamic>{
            'limit': e.limit,
            'current_count': e.currentCount,
            'message': e.message,
            'current_attempt_id': _connectAttemptId,
            'ui_state': _state.name,
            'runtime_session_id': _runtimeSessionId,
          },
        );
        return;
      }
      _traceConnectPhase(
        'background_session_start_device_limit',
        attemptId: attemptId,
        source: source,
        sessionId: runtimeSessionId,
        deviceId: deviceId,
        config: config,
        extra: <String, dynamic>{
          'limit': e.limit,
          'current_count': e.currentCount,
          'message': e.message,
        },
      );
      await _handleAccessRequired(
        source: 'background_session_start',
        message: e.message,
        sessionId: runtimeSessionId,
        deviceId: deviceId,
        deviceLimit: e,
      );
    } catch (e) {
      _traceConnectPhase(
        'background_session_start_failed',
        attemptId: attemptId,
        source: source,
        sessionId: runtimeSessionId,
        deviceId: deviceId,
        config: config,
        extra: <String, dynamic>{'error': e.toString()},
      );
      unawaited(_api.log(
        event: 'background_session_start_failed',
        level: 'warning',
        sessionId: runtimeSessionId,
        deviceId: deviceId,
        details: <String, dynamic>{
          'error': e.toString(),
          'protocol': config.protocol,
          'server_id': serverId,
          'source': source,
          'policy': 'keep_tunnel_running',
        },
      ));
    }
  }

  Future<SimpleVpnConfig> _fetchConfigWithRetry({
    required int? serverId,
    required String? deviceId,
    required String protocol,
    required int attemptId,
    required String source,
    String reason = 'connect',
  }) async {
    Object? lastError;
    StackTrace? lastStackTrace;
    final maxAttempts = 1 + _configFetchRetryDelays.length;
    for (var index = 0; index < maxAttempts; index += 1) {
      final retryNumber = index + 1;
      try {
        final config = await _api.fetchConfig(
          serverId: serverId,
          deviceId: deviceId,
          protocol: protocol,
        );
        if (index > 0) {
          _traceConnectPhase(
            'config_fetch_retry_success',
            attemptId: attemptId,
            source: source,
            deviceId: deviceId,
            config: config,
            extra: <String, dynamic>{
              'retry_number': retryNumber,
              'max_attempts': maxAttempts,
              'reason': reason,
            },
          );
        }
        return config;
      } on SimpleVpnAccessRequiredException {
        rethrow;
      } on _SimpleVpnConnectCancelled {
        rethrow;
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
      }

      if (index >= _configFetchRetryDelays.length) break;
      final delay = _configFetchRetryDelays[index];
      _traceConnectPhase(
        'config_fetch_retry_wait',
        attemptId: attemptId,
        source: source,
        deviceId: deviceId,
        extra: <String, dynamic>{
          'server_id': serverId,
          'protocol': protocol,
          'retry_number': retryNumber,
          'next_retry_number': retryNumber + 1,
          'max_attempts': maxAttempts,
          'delay_ms': delay.inMilliseconds,
          'reason': reason,
          'error': lastError.toString(),
        },
      );
      unawaited(_api.log(
        event: 'config_fetch_retry_wait',
        deviceId: deviceId,
        details: <String, dynamic>{
          'server_id': serverId,
          'protocol': protocol,
          'retry_number': retryNumber,
          'next_retry_number': retryNumber + 1,
          'max_attempts': maxAttempts,
          'delay_ms': delay.inMilliseconds,
          'reason': reason,
          'error': lastError.toString(),
          'source': source,
        },
      ).catchError((_) {}));
      _setConnectionProgress(
        retryNumber == 1
            ? 'Сеть нестабильна. Продолжаем...'
            : 'Продолжаем подготовку, ждём ответ сети...',
        percent: 36 + index * 4,
        badge: 'Сеть нестабильна',
      );
      _throwIfConnectCancelled(attemptId);
      await Future.delayed(delay);
      _throwIfConnectCancelled(attemptId);
    }
    _traceConnectPhase(
      'config_fetch_retries_exhausted',
      attemptId: attemptId,
      source: source,
      deviceId: deviceId,
      extra: <String, dynamic>{
        'server_id': serverId,
        'protocol': protocol,
        'max_attempts': maxAttempts,
        'reason': reason,
        'last_error': lastError?.toString(),
      },
    );
    if (lastError != null) {
      Error.throwWithStackTrace(
          lastError, lastStackTrace ?? StackTrace.current);
    }
    throw Exception('Simple VPN config fetch failed');
  }

  String _configCacheKey(
      {required int? serverId,
      required String protocol,
      required String? deviceId}) {
    final resolvedServerId =
        serverId == null || serverId <= 0 ? 'default' : serverId.toString();
    final resolvedDeviceId =
        (deviceId == null || deviceId.isEmpty) ? 'default' : deviceId;
    return 'simple_vpn_config_v3:$resolvedDeviceId:$protocol:$resolvedServerId';
  }

  Future<SimpleVpnConfig?> _readCachedConfig(
      {required int? serverId,
      required String protocol,
      required String? deviceId}) async {
    final key = _configCacheKey(
        serverId: serverId, protocol: protocol, deviceId: deviceId);
    final raw = await _cacheService.getString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final config = SimpleVpnConfig.fromJson(map);
      if (config.config.isEmpty ||
          (config.engine != 'amneziawg' &&
              config.engine != 'xray' &&
              config.engine != 'hysteria2')) {
        return null;
      }
      return config;
    } catch (_) {
      await _cacheService.remove(key);
      return null;
    }
  }

  Future<void> _writeCachedConfig(SimpleVpnConfig config,
      {required int? serverId, required String? deviceId}) async {
    final key = _configCacheKey(
        serverId: serverId, protocol: config.protocol, deviceId: deviceId);
    await _cacheService.setString(key, jsonEncode(config.toJson()),
        ttl: _configCacheTtl);
  }

  Future<void> _removeCachedConfig(
      {required int? serverId,
      required String protocol,
      required String? deviceId}) async {
    final key = _configCacheKey(
        serverId: serverId, protocol: protocol, deviceId: deviceId);
    await _cacheService.remove(key);
  }

  Future<void> _persistActiveSessionId(String sessionId) async {
    if (sessionId.isEmpty) return;
    await _cacheService.setString(_activeSessionCacheKey, sessionId);
  }

  Future<void> _persistActiveRuntimeSessionId(String? sessionId) async {
    final value = sessionId?.trim();
    if (value == null || value.isEmpty) return;
    await _cacheService.setString(_activeRuntimeSessionCacheKey, value);
  }

  Future<String?> _readActiveSessionId() async {
    final cached =
        (await _cacheService.getString(_activeSessionCacheKey))?.trim();
    return cached == null || cached.isEmpty ? null : cached;
  }

  Future<String?> _readActiveRuntimeSessionId() async {
    final cached =
        (await _cacheService.getString(_activeRuntimeSessionCacheKey))?.trim();
    return cached == null || cached.isEmpty ? null : cached;
  }

  Future<void> _clearActiveSessionId() async {
    await _cacheService.remove(_activeSessionCacheKey);
    await _cacheService.remove(_activeRuntimeSessionCacheKey);
  }

  Future<Map<String, dynamic>> _desktopVpnDiagnosticsForLogs() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      return <String, dynamic>{};
    }
    return NativeVpnService.getDesktopVpnDiagnostics();
  }

  Future<int?> _readSelectedServerId() async {
    final cached =
        (await _cacheService.getString(_selectedServerCacheKey))?.trim();
    if (cached == null || cached.isEmpty) return null;
    return int.tryParse(cached);
  }

  Future<void> _persistSelectedServerId(int? serverId) async {
    if (serverId == null || serverId <= 0) return;
    await _cacheService.setString(_selectedServerCacheKey, serverId.toString());
  }

  Future<String?> _readSelectedProtocolId() async {
    final cached =
        (await _cacheService.getString(_selectedProtocolCacheKey))?.trim();
    return _isProtocolSupportedByRuntime(cached) ? cached : null;
  }

  Future<void> _persistSelectedProtocolId(String? protocolId) async {
    if (!_isProtocolSupportedByRuntime(protocolId)) return;
    await _cacheService.setString(_selectedProtocolCacheKey, protocolId!);
  }

  void _rememberConnectedConfig({
    required SimpleVpnConfig config,
    required String? deviceId,
    required bool configFromCache,
  }) {
    _lastConnectedConfig = config;
    _lastConnectedDeviceId = deviceId;
    _lastConnectedConfigFromCache = configFromCache;
    _nodeTrafficVerifiedForSession = false;
    if (_isProtocolSupportedByRuntime(config.protocol)) {
      final matchedProtocol = _protocols.firstWhere(
        (protocol) => protocol.id == config.protocol,
        orElse: () => SimpleVpnProtocol(
          id: config.protocol,
          engine: config.engine,
          status: 'active',
          role: 'last_connected',
        ),
      );
      _selectedProtocol = matchedProtocol;
      unawaited(_persistSelectedProtocolId(config.protocol));
    }
  }

  Future<void> _checkEntitlementWhileConnected(
      {String source = 'verify'}) async {
    if (_disposed || _state != SimpleVpnState.connected) return;
    try {
      await _api.verifySession(
        sessionId:
            _backendSessionId(_sessionId ?? await _readActiveSessionId()),
        deviceId: _lastConnectedDeviceId ?? await _resolveDeviceId(),
        serverId: _lastConnectedConfig?.server?.id ?? _selectedServer?.id,
        protocol: _lastConnectedConfig?.protocol ?? _selectedProtocol.id,
      );
    } on SimpleVpnAccessRequiredException catch (e) {
      await _handleAccessRequired(source: source, message: e.message);
    } catch (_) {
      // Network verification is best-effort; entitlement glitches must not
      // tear down an already committed tunnel.
    }
  }

  Future<void> _handleAccessRequired({
    required String source,
    String? message,
    String? sessionId,
    String? deviceId,
    DeviceLimitException? deviceLimit,
  }) async {
    final isDeviceLimit =
        deviceLimit != null || _isDeviceLimitAccessMessage(message);
    _accessRequired = !isDeviceLimit;
    _error = isDeviceLimit ? null : (message ?? 'Требуется активная подписка');
    _stopEntitlementTimer();
    final sid = sessionId ?? _sessionId ?? await _readActiveSessionId();
    final did = deviceId ?? _lastConnectedDeviceId;
    final runtimeSid =
        _runtimeSessionId ?? await _readActiveRuntimeSessionId() ?? sid;
    if (_state == SimpleVpnState.connected && !isDeviceLimit) {
      unawaited(_api.log(
        event: 'access_required_stop_suppressed',
        level: 'warning',
        sessionId: sid,
        deviceId: did,
        details: <String, dynamic>{
          'source': source,
          'reason': 'subscription_required',
          'policy': 'keep_tunnel_until_explicit_stop',
        },
      ));
      _notify();
      return;
    }
    final disconnectReason = isDeviceLimit ? 'device_limit' : 'access_expired';
    final backendSid = _backendSessionId(sid);
    await _runtime
        .disconnect(
          reason: disconnectReason,
          source: source,
          sessionId: runtimeSid,
          includeLegacy: true,
        )
        .catchError((_) => false);
    await _api
        .stopSession(
          sessionId: backendSid,
          reason: disconnectReason,
          deviceId: did,
        )
        .catchError((_) {});
    if (isDeviceLimit) {
      _onDeviceLimit?.call(deviceLimit ??
          DeviceLimitException(
            message ?? 'Превышен лимит устройств',
          ));
    }
    unawaited(_api.log(
      event: isDeviceLimit
          ? 'device_limit_active_disconnect'
          : 'access_required_disconnect',
      level: 'warning',
      sessionId: sid,
      deviceId: did,
      details: <String, dynamic>{
        'source': source,
        'reason': disconnectReason,
        'runtime_session_id': runtimeSid,
        'backend_session_id': backendSid,
      },
    ));
    _sessionId = null;
    await _clearActiveSessionId();
    _lastConnectedConfig = null;
    _lastConnectedDeviceId = null;
    _runtimeSessionId = null;
    _nodeTrafficVerifiedForSession = false;
    _clearConnectionProgress();
    _setState(SimpleVpnState.disconnected);
  }

  bool _isDeviceLimitAccessMessage(String? message) {
    final value = (message ?? '').toLowerCase();
    return value.contains('device_limit_exceeded') ||
        value.contains('device limit') ||
        value.contains('лимит устройств') ||
        value.contains('превышен лимит');
  }

  void _scheduleNodeTrafficVerification() {
    final config = _lastConnectedConfig;
    if (config == null || _nodeVerificationInFlight) return;
    var runtimeSessionId = _runtimeSessionId;
    if (runtimeSessionId == null || runtimeSessionId.isEmpty) {
      runtimeSessionId = _activeConnectSessionId;
    }
    final backendSessionId = _backendSessionId(_sessionId);
    final analyticsSessionId =
        (runtimeSessionId != null && runtimeSessionId.isNotEmpty)
            ? runtimeSessionId
            : backendSessionId;
    if (analyticsSessionId == null || analyticsSessionId.isEmpty) return;
    unawaited(_verifyNodeTrafficForAnalytics(
      config: config,
      analyticsSessionId: analyticsSessionId,
      runtimeSessionId: runtimeSessionId,
      backendSessionId: backendSessionId,
      deviceId: _lastConnectedDeviceId,
      configFromCache: _lastConnectedConfigFromCache,
    ));
  }

  Future<void> _verifyNodeTrafficForAnalytics({
    required SimpleVpnConfig config,
    required String analyticsSessionId,
    required String? runtimeSessionId,
    required String? backendSessionId,
    required String? deviceId,
    required bool configFromCache,
  }) async {
    if (_nodeVerificationInFlight) return;
    _nodeVerificationInFlight = true;
    const delays = <Duration>[
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
    ];

    try {
      for (var attempt = 0; attempt < delays.length; attempt++) {
        await Future<void>.delayed(delays[attempt]);
        if (_disposed || _state != SimpleVpnState.connected) return;
        final currentRuntimeSessionId = _runtimeSessionId;
        final currentBackendSessionId = _backendSessionId(_sessionId);
        if (runtimeSessionId != null &&
            runtimeSessionId.isNotEmpty &&
            currentRuntimeSessionId != null &&
            currentRuntimeSessionId.isNotEmpty &&
            currentRuntimeSessionId != runtimeSessionId) {
          return;
        }
        if ((runtimeSessionId == null || runtimeSessionId.isEmpty) &&
            backendSessionId != null &&
            backendSessionId.isNotEmpty &&
            currentBackendSessionId != null &&
            currentBackendSessionId.isNotEmpty &&
            currentBackendSessionId != backendSessionId) {
          return;
        }

        try {
          final result = await _api.verifySession(
            sessionId: backendSessionId,
            deviceId: deviceId,
            serverId: config.server?.id ?? _selectedServer?.id,
            protocol: config.protocol,
          );
          final details = <String, dynamic>{
            'server_id':
                result.serverId ?? config.server?.id ?? _selectedServer?.id,
            'protocol': config.protocol,
            'vpn_ip': result.vpnIp,
            'handshake_age_sec': result.handshakeAgeSec,
            'rx_bytes': result.rxBytes,
            'tx_bytes': result.txBytes,
            'reason': result.reason,
            'config_from_cache': configFromCache,
            'attempt': attempt + 1,
            'runtime_session_id': runtimeSessionId,
            'backend_session_id': backendSessionId,
            'connection_session_id': analyticsSessionId,
            'vpn_session_id': analyticsSessionId,
          };
          final hasServerSideNodeVerify = {
            'graniwg',
            'amneziawg',
            'awg',
          }.contains(config.protocol.toLowerCase());
          details['verification_scope'] =
              hasServerSideNodeVerify ? 'server_node' : 'client_runtime';
          details['verification_source'] = hasServerSideNodeVerify
              ? 'server_node'
              : 'client_traffic_first_seen';
          details['node_verified'] = hasServerSideNodeVerify;
          unawaited(_api.log(
            event: hasServerSideNodeVerify
                ? (result.verified
                    ? 'node_data_verified'
                    : 'node_data_unverified')
                : (result.verified
                    ? 'client_runtime_verified'
                    : 'client_runtime_unverified'),
            level: result.verified ? 'info' : 'warning',
            sessionId: analyticsSessionId,
            deviceId: deviceId,
            details: details,
          ));
          if (!result.verified) continue;
          if (!hasServerSideNodeVerify) {
            // VLESS/HY2 session/verify only proves that the client runtime is
            // alive. Their funnel proof is emitted from a native traffic tick
            // with positive local TUN counters.
            return;
          }

          await _api.log(
            event: 'vpn_data_verified',
            sessionId: analyticsSessionId,
            deviceId: deviceId,
            details: details,
          );
          if (!_nodeTrafficVerifiedForSession) {
            _nodeTrafficVerifiedForSession = true;
            await _analyticsService.logVpnDataVerified(
              serverId: result.serverId ??
                  config.server?.id ??
                  _selectedServer?.id ??
                  0,
              protocol: config.protocol,
              sessionId: analyticsSessionId,
              handshakeAgeSec: result.handshakeAgeSec,
              rxBytes: result.rxBytes,
              txBytes: result.txBytes,
              fromCache: configFromCache,
            );
          }
          return;
        } on SimpleVpnAccessRequiredException catch (e) {
          await _handleAccessRequired(
            source: 'traffic_verify',
            message: e.message,
            sessionId: sessionId,
            deviceId: deviceId,
          );
          return;
        } catch (e) {
          unawaited(_api.log(
            event: 'node_data_verify_failed',
            level: 'warning',
            sessionId: analyticsSessionId,
            deviceId: deviceId,
            details: <String, dynamic>{
              'error': e.toString(),
              'attempt': attempt + 1,
              'runtime_session_id': runtimeSessionId,
              'backend_session_id': backendSessionId,
              'connection_session_id': analyticsSessionId,
              'vpn_session_id': analyticsSessionId,
            },
          ));
        }
      }
    } finally {
      _nodeVerificationInFlight = false;
    }
  }

  Future<void> syncNativeState() async {
    if (isBusy) return;
    try {
      final amneziaWgConnected = await _runtime.getAmneziaWgStatus();
      final nativeConnected = await _runtime.getNativeConnectionStatus();
      final connected = amneziaWgConnected == true || nativeConnected == true;
      if (connected == true) {
        _sessionId ??= await _readActiveSessionId();
        _runtimeSessionId ??= await _readActiveRuntimeSessionId();
        if (_state != SimpleVpnState.connected) {
          _setState(SimpleVpnState.connected);
        }
        _scheduleNodeTrafficVerification();
        unawaited(_checkEntitlementWhileConnected(source: 'native_sync'));
      } else if (amneziaWgConnected == false &&
          nativeConnected == false &&
          _state == SimpleVpnState.connected) {
        _sessionId = null;
        await _clearActiveSessionId();
        _lastConnectedConfig = null;
        _lastConnectedDeviceId = null;
        _runtimeSessionId = null;
        _nodeTrafficVerifiedForSession = false;
        _stopEntitlementTimer();
        _setState(SimpleVpnState.disconnected);
      }
    } catch (_) {
      // Native state sync is best-effort; never block the working VPN button.
    }
  }

  Future<void> syncNativeUiState({String source = 'native_ui_sync'}) async {
    try {
      final amneziaWgConnected = await _runtime.getAmneziaWgStatus();
      final nativeConnected = await _runtime.getNativeConnectionStatus();
      final connected = amneziaWgConnected == true || nativeConnected == true;
      if (connected) {
        if (_state != SimpleVpnState.disconnecting) {
          await _adoptNativeConnectedEvent(source: source);
        }
      } else if (amneziaWgConnected == false && nativeConnected == false) {
        if (_state == SimpleVpnState.connected ||
            _state == SimpleVpnState.disconnecting) {
          await _adoptNativeDisconnectedEvent(source: source);
        }
      }
    } catch (_) {
      // Local native state sync is a UI helper only.
    }
  }

  void _startNativeStateSubscription() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _nativeStateSubscription = NativeVpnService.nativeVpnStateEvents.listen(
      _handleNativeStateEvent,
      onError: (_) {
        // Native state events are diagnostic/UX assistance. Polling sync remains
        // the fallback, so stream errors must not break the VPN button.
      },
    );
  }

  void _handleNativeStateEvent(Map<dynamic, dynamic> event) {
    if (_disposed) return;
    final emitType = event['emit_type']?.toString();
    if (emitType == 'traffic') {
      _handleNativeTrafficProof(event);
      return;
    }
    if (emitType != 'state') return;

    final serviceState =
        event['service_state']?.toString().toLowerCase().trim() ?? '';
    final eventSessionId = event['runtime_session_id']?.toString().trim() ?? '';
    final expectedSessionId = _currentNativeRuntimeSessionId();
    if (eventSessionId.isNotEmpty &&
        expectedSessionId != null &&
        expectedSessionId.isNotEmpty &&
        eventSessionId != expectedSessionId) {
      _traceNativeStateEvent(
        event,
        decision: 'ignored',
        reason: 'stale_session',
      );
      debugPrint(
          'SimpleVpnController: ignore stale native event service_state=$serviceState event_session=$eventSessionId expected_session=$expectedSessionId');
      return;
    }
    final hasExpectedSession =
        expectedSessionId != null && expectedSessionId.isNotEmpty;
    final sessionlessStopWhileConnecting = eventSessionId.isEmpty &&
        _state == SimpleVpnState.connecting &&
        (serviceState == 'disconnecting' ||
            serviceState == 'idle' ||
            serviceState == 'off');
    if (sessionlessStopWhileConnecting) {
      _traceNativeStateEvent(
        event,
        decision: 'ignored',
        reason: 'sessionless_stop_while_connecting',
      );
      debugPrint(
          'SimpleVpnController: ignore sessionless native stop while connecting service_state=$serviceState');
      return;
    }
    final sessionlessStopTail = eventSessionId.isEmpty &&
        hasExpectedSession &&
        _state == SimpleVpnState.connecting &&
        (serviceState == 'disconnecting' ||
            serviceState == 'idle' ||
            serviceState == 'off' ||
            serviceState == 'error');
    if (sessionlessStopTail) {
      _traceNativeStateEvent(
        event,
        decision: 'ignored',
        reason: 'sessionless_stop_tail',
      );
      debugPrint(
          'SimpleVpnController: ignore sessionless native stop tail service_state=$serviceState expected_session=$expectedSessionId');
      return;
    }
    final runtimeError = event['runtime_error']?.toString().trim();
    final connected = event['connected'] == true ||
        serviceState == 'local_up' ||
        serviceState == 'dataplane_verified' ||
        serviceState == 'committed';

    if (connected) {
      if (_state == SimpleVpnState.disconnecting) {
        _traceNativeStateEvent(
          event,
          decision: 'ignored',
          reason: 'connected_while_disconnecting',
        );
        debugPrint(
            'SimpleVpnController: ignore native connected event while disconnecting service_state=$serviceState');
        return;
      }
      _traceNativeStateEvent(event, decision: 'adopt_connected');
      unawaited(
          _adoptNativeConnectedEvent(source: 'native_event_$serviceState'));
      return;
    }

    switch (serviceState) {
      case 'prepare':
        _traceNativeStateEvent(event, decision: 'prepare');
        if (_state == SimpleVpnState.disconnected ||
            _state == SimpleVpnState.error) {
          _error = null;
          _setState(SimpleVpnState.connecting);
        }
        break;
      case 'disconnecting':
        _traceNativeStateEvent(event, decision: 'disconnecting');
        if (_state == SimpleVpnState.connected ||
            _state == SimpleVpnState.connecting) {
          _setState(SimpleVpnState.disconnecting);
        }
        break;
      case 'idle':
        _traceNativeStateEvent(event, decision: 'adopt_disconnected');
        unawaited(
          _adoptNativeDisconnectedEvent(source: 'native_event_idle'),
        );
        break;
      case 'error':
        _traceNativeStateEvent(event, decision: 'error');
        _error ??= runtimeError != null && runtimeError.isNotEmpty
            ? runtimeError
            : 'VPN runtime error';
        _setState(SimpleVpnState.error);
        break;
    }
  }

  int _nativeTrafficCounter(Map<dynamic, dynamic> event, String key) {
    final value = event[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  void _handleNativeTrafficProof(Map<dynamic, dynamic> event) {
    if (_disposed ||
        _state != SimpleVpnState.connected ||
        _nodeTrafficVerifiedForSession) {
      return;
    }
    final rxBytes = _nativeTrafficCounter(event, 'rx_bytes');
    final txBytes = _nativeTrafficCounter(event, 'tx_bytes');
    if (rxBytes <= 0 && txBytes <= 0) return;

    final eventSessionId = event['runtime_session_id']?.toString().trim() ?? '';
    final expectedSessionId = _currentNativeRuntimeSessionId();
    if (eventSessionId.isNotEmpty &&
        expectedSessionId != null &&
        expectedSessionId.isNotEmpty &&
        eventSessionId != expectedSessionId) {
      return;
    }

    final config = _lastConnectedConfig;
    final deviceId = _lastConnectedDeviceId;
    final analyticsSessionId =
        (expectedSessionId != null && expectedSessionId.isNotEmpty)
            ? expectedSessionId
            : _backendSessionId(_sessionId);
    if (config == null ||
        deviceId == null ||
        deviceId.isEmpty ||
        analyticsSessionId == null ||
        analyticsSessionId.isEmpty) {
      return;
    }

    _nodeTrafficVerifiedForSession = true;
    final serverId = config.server?.id ?? _selectedServer?.id ?? 0;
    unawaited(_api.log(
      event: 'vpn_data_verified',
      sessionId: analyticsSessionId,
      deviceId: deviceId,
      details: <String, dynamic>{
        'server_id': serverId,
        'protocol': config.protocol,
        'rx_bytes': rxBytes,
        'tx_bytes': txBytes,
        'runtime_session_id': expectedSessionId,
        'backend_session_id': _backendSessionId(_sessionId),
        'connection_session_id': analyticsSessionId,
        'vpn_session_id': analyticsSessionId,
        'verification_scope': 'client_tun',
        'verification_source': 'native_tun_counters',
        'node_verified': false,
      },
    ));
    unawaited(_analyticsService.logVpnDataVerified(
      serverId: serverId,
      protocol: config.protocol,
      sessionId: analyticsSessionId,
      rxBytes: rxBytes,
      txBytes: txBytes,
      fromCache: _lastConnectedConfigFromCache,
    ));
  }

  Future<void> _adoptNativeConnectedEvent({required String source}) async {
    if (_disposed) return;
    _sessionId ??= await _readActiveSessionId();
    _runtimeSessionId ??= await _readActiveRuntimeSessionId();
    if (_disposed) return;
    _error = null;
    if (_state != SimpleVpnState.connected) {
      _setState(SimpleVpnState.connected);
    }
    // Native EventChannel is a local UI synchronization signal. Do not start
    // backend checks from here: Android can emit LOCAL_UP, DATAPLANE_VERIFIED
    // and COMMITTED for one tunnel, plus an initial state event on subscribe.
    // Backend verification and entitlement checks stay in the explicit
    // connect/sync/timer paths where they are already guarded.
  }

  Future<void> _adoptNativeDisconnectedEvent({required String source}) async {
    if (_disposed || _state == SimpleVpnState.disconnected) return;
    _sessionId = null;
    await _clearActiveSessionId();
    if (_disposed) return;
    _lastConnectedConfig = null;
    _lastConnectedDeviceId = null;
    _lastConnectedConfigFromCache = false;
    _runtimeSessionId = null;
    _nodeTrafficVerifiedForSession = false;
    _stopEntitlementTimer();
    _error = null;
    _setState(SimpleVpnState.disconnected);
  }

  Future<void> toggle({String source = 'simple_vpn'}) async {
    if (_state == SimpleVpnState.connecting) {
      await cancelConnect(source: source);
      return;
    }
    if (isBusy) return;
    if (isConnected) {
      await disconnect(source: source);
    } else {
      await connect(source: source);
    }
  }

  void _throwIfConnectCancelled(int attemptId) {
    if (_connectCancelRequested || attemptId != _connectAttemptId) {
      throw const _SimpleVpnConnectCancelled();
    }
  }

  bool _isCurrentConnectAttempt(int attemptId) {
    return !_disposed && attemptId == _connectAttemptId;
  }

  bool _isCurrentRuntimeSession(String? sessionId) {
    final value = sessionId?.trim();
    if (value == null || value.isEmpty) return false;
    final runtime = _currentNativeRuntimeSessionId();
    return runtime != null && runtime.isNotEmpty && runtime == value;
  }

  bool _isCurrentConnectOwner({
    required int attemptId,
    String? sessionId,
  }) {
    if (!_isCurrentConnectAttempt(attemptId)) return false;
    final value = sessionId?.trim();
    if (value == null || value.isEmpty) return true;
    return _isCurrentRuntimeSession(value);
  }

  Future<void> cancelConnect({String source = 'simple_vpn'}) async {
    if (_state != SimpleVpnState.connecting) return;
    _connectCancelRequested = true;
    _connectAttemptId++;

    final sid = _activeConnectSessionId ?? _sessionId;
    final backendSid = _backendSessionId(_sessionId);
    final did = _activeConnectDeviceId ?? _lastConnectedDeviceId;
    final runtimeSid =
        _runtimeSessionId ?? await _readActiveRuntimeSessionId() ?? sid;
    _sessionId = null;
    await _clearActiveSessionId();
    _lastConnectedConfig = null;
    _lastConnectedDeviceId = null;
    _runtimeSessionId = null;
    _nodeTrafficVerifiedForSession = false;
    _clearConnectionProgress();
    _error = null;
    _setState(SimpleVpnState.disconnected);

    unawaited(_cleanupCancelledConnect(
      sessionId: runtimeSid,
      backendSessionId: backendSid,
      deviceId: did,
      source: source,
    ));
  }

  Future<void> _cleanupCancelledConnect({
    required String? sessionId,
    String? backendSessionId,
    required String? deviceId,
    required String source,
  }) async {
    await _runtime
        .disconnect(
          reason: 'connect_cancelled',
          source: source,
          sessionId: sessionId,
        )
        .catchError((_) => false);
    final backendSid = backendSessionId ?? _backendSessionId(sessionId);
    if (backendSid != null && backendSid.isNotEmpty) {
      await _api
          .stopSession(
            sessionId: backendSid,
            reason: 'user_cancel',
            deviceId: deviceId,
          )
          .catchError((_) {});
    }
  }

  Future<Map<String, dynamic>> _collectNetworkPreflight({
    required String source,
  }) async {
    const publicProbePolicy =
        'native_multi_probe: 1.1.1.1_http, captive_http, gstatic_https, example_https';
    try {
      final diagnostics = await NativeVpnService.getNetworkDiagnostics()
          .timeout(const Duration(seconds: 5));
      final enriched = <String, dynamic>{
        ...diagnostics,
        'probe_policy': publicProbePolicy,
        'probe_note':
            'diagnostic_only; connection is not blocked by public probe result',
      };
      debugPrint('SimpleVpnController.network_preflight: $enriched');
      return enriched;
    } catch (e) {
      final diagnostics = <String, dynamic>{
        'network_type': 'unknown',
        'underlying_network_type': 'unknown',
        'underlying_network_available': false,
        'internet_without_vpn_ok': false,
        'underlying_internet_ok': false,
        'underlying_probe_error': e.toString(),
        'probe_policy': publicProbePolicy,
        'probe_note':
            'diagnostic_only; connection is not blocked by public probe result',
        'source': source,
      };
      debugPrint('SimpleVpnController.network_preflight_failed: $diagnostics');
      return diagnostics;
    }
  }

  void _traceConnectPhase(
    String phase, {
    int? attemptId,
    String? source,
    String? sessionId,
    String? deviceId,
    SimpleVpnConfig? config,
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) {
    final payload = <String, dynamic>{
      'phase': phase,
      'attempt_id': attemptId ?? _connectAttemptId,
      'source': source,
      'ui_state': _state.name,
      'session_id': sessionId ?? _activeConnectSessionId ?? _sessionId,
      'device_id': deviceId ?? _activeConnectDeviceId ?? _lastConnectedDeviceId,
      'protocol': config?.protocol ?? _selectedProtocol.id,
      'server_id': config?.server?.id ?? _selectedServer?.id,
      'server_name': config?.serverName ?? _selectedServer?.name,
      'config_from_cache': _lastConnectedConfigFromCache,
      'progress_text': _connectionProgressText,
      'progress_percent': _connectionProgressPercent,
      'mode_badge': _connectionModeBadge,
      if (_error != null) 'error': _error,
      ...extra,
    };
    payload.removeWhere((_, value) => value == null);
    debugPrint('[CONNECT_TRACE] ${jsonEncode(payload)}');
  }

  void _traceNativeStateEvent(
    Map<dynamic, dynamic> event, {
    required String decision,
    String? reason,
  }) {
    final payload = <String, dynamic>{
      'decision': decision,
      if (reason != null && reason.isNotEmpty) 'reason': reason,
      'ui_state': _state.name,
      'service_state': event['service_state']?.toString(),
      'event_session_id': event['runtime_session_id']?.toString(),
      'expected_session_id': _currentNativeRuntimeSessionId(),
      'backend_session_id': _sessionId,
      'connected': event['connected'] == true,
      'runtime_error': event['runtime_error']?.toString(),
      'protocol': _selectedProtocol.id,
      'server_id': _selectedServer?.id,
    };
    payload.removeWhere((_, value) => value == null || value == '');
    debugPrint('[NATIVE_STATE_TRACE] ${jsonEncode(payload)}');
  }

  Future<Map<String, dynamic>> _collectUnifiedDiagnosticDump({
    required String source,
    required String phase,
    String? sessionId,
    String? protocol,
    int? serverId,
    String? serverName,
    bool includeNetworkProbe = true,
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) async {
    try {
      final dump = await NativeVpnService.getUnifiedDiagnosticDump(
        source: source,
        phase: phase,
        protocol: protocol ?? _selectedProtocol.id,
        serverId: serverId ?? _selectedServer?.id,
        serverName: serverName ?? _selectedServer?.name,
        sessionId: sessionId ?? _sessionId,
        includeNetworkProbe: includeNetworkProbe,
      ).timeout(const Duration(seconds: 8));
      return <String, dynamic>{
        ...dump,
        if (extra.isNotEmpty) 'extra': extra,
        ...extra,
      };
    } catch (e) {
      return <String, dynamic>{
        'diagnostic_schema': 'grani_unified_vpn_dump_v1',
        'diagnostic_source': source,
        'diagnostic_phase': phase,
        'diagnostic_error': e.toString(),
        'protocol': protocol ?? _selectedProtocol.id,
        if ((serverId ?? _selectedServer?.id) != null)
          'server_id': serverId ?? _selectedServer?.id,
        if ((serverName ?? _selectedServer?.name) != null)
          'server_name': serverName ?? _selectedServer?.name,
        if ((sessionId ?? _sessionId) != null)
          'connection_session_id': sessionId ?? _sessionId,
        ...extra,
      };
    }
  }

  Future<void> _logRuntimeDiagnosticDump({
    required String phase,
    required String source,
    required String? deviceId,
    String? sessionId,
    String? protocol,
    int? serverId,
    String? serverName,
    String level = 'info',
    bool includeNetworkProbe = true,
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) async {
    if (deviceId == null || deviceId.isEmpty) return;
    final dump = await _collectUnifiedDiagnosticDump(
      source: source,
      phase: phase,
      sessionId: sessionId,
      protocol: protocol,
      serverId: serverId,
      serverName: serverName,
      includeNetworkProbe: includeNetworkProbe,
      extra: extra,
    );
    await _api.log(
      event: 'runtime_diagnostic_dump_$phase',
      level: level,
      sessionId: sessionId ?? _sessionId,
      deviceId: deviceId,
      details: <String, dynamic>{
        ...dump,
        'diagnostic_event': 'runtime_diagnostic_dump',
      },
    );
  }

  Future<bool> _isRuntimeDown() async {
    bool? nativeConnected;
    bool? awgConnected;
    try {
      nativeConnected = await _runtime
          .getNativeConnectionStatus()
          .timeout(_runtimeDownStatusTimeout);
    } catch (_) {
      nativeConnected = null;
    }
    try {
      awgConnected = await _runtime
          .getAmneziaWgStatus()
          .timeout(_runtimeDownStatusTimeout);
    } catch (_) {
      awgConnected = null;
    }
    return nativeConnected == false && awgConnected == false;
  }

  Future<bool> _waitForRuntimeDown({
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _isRuntimeDown()) return true;
      await Future<void>.delayed(_runtimeDownPollInterval);
    }
    return _isRuntimeDown();
  }

  bool _diagnosticBool(dynamic value) {
    if (value is bool) return value;
    final text = value?.toString().trim().toLowerCase();
    return text == 'true' || text == '1' || text == 'yes';
  }

  Future<bool> _isNativeAndAndroidVpnAlreadyDown({
    required String source,
  }) async {
    try {
      final dump = await _collectUnifiedDiagnosticDump(
        source: source,
        phase: 'disconnect_barrier_precheck',
        includeNetworkProbe: false,
      ).timeout(const Duration(milliseconds: 900));
      final nativeActiveOrClosing =
          _diagnosticBool(dump['native_active_or_closing']);
      final androidSystemVpnActive =
          _diagnosticBool(dump['android_system_vpn_active']);
      return !nativeActiveOrClosing && !androidSystemVpnActive;
    } catch (_) {
      return false;
    }
  }

  Future<void> _waitForDisconnectBarrier({
    required int attemptId,
    required String source,
  }) async {
    final pending = _disconnectInFlight;
    if (pending == null) return;

    if (await _isNativeAndAndroidVpnAlreadyDown(source: source)) {
      _traceConnectPhase(
        'disconnect_cleanup_already_down',
        attemptId: attemptId,
        source: source,
        extra: <String, dynamic>{
          'disconnect_operation_id': _disconnectOperationId,
          'precheck': 'native_and_android_vpn_down',
        },
      );
      return;
    }

    _setConnectionProgress(
      'Завершаем прошлое соединение...',
      percent: 12,
      badge: 'Очистка соединения',
    );
    _traceConnectPhase(
      'waiting_for_disconnect_cleanup',
      attemptId: attemptId,
      source: source,
      extra: <String, dynamic>{
        'disconnect_operation_id': _disconnectOperationId,
        'timeout_ms': _disconnectBarrierTimeout.inMilliseconds,
      },
    );

    var timedOut = false;
    try {
      await pending.timeout(_disconnectBarrierTimeout);
    } on TimeoutException {
      timedOut = true;
    }
    _throwIfConnectCancelled(attemptId);
    _traceConnectPhase(
      'disconnect_cleanup_wait_done',
      attemptId: attemptId,
      source: source,
      extra: <String, dynamic>{
        'disconnect_operation_id': _disconnectOperationId,
        'timed_out': timedOut,
      },
    );
  }

  Future<void> connect({String source = 'simple_vpn'}) async {
    if (_state == SimpleVpnState.connecting || isConnected) return;
    if (_state == SimpleVpnState.disconnecting && _disconnectInFlight == null) {
      return;
    }
    final attemptId = ++_connectAttemptId;
    _connectCancelRequested = false;
    _activeConnectSessionId = null;
    _activeConnectDeviceId = null;
    _runtimeSessionId = null;
    _setState(SimpleVpnState.connecting);
    _error = null;
    _setConnectionProgress('Проверяем доступ...', percent: 8);
    _startConnectProgressTimer();
    _traceConnectPhase(
      'connect_begin',
      attemptId: attemptId,
      source: source,
    );

    String? sessionId;
    String? backendSessionId;
    String? deviceId;
    SimpleVpnConfig? config;
    bool configFromCache = false;
    bool backendSessionDeferred = false;
    var networkPreflight = <String, dynamic>{};
    try {
      _setConnectionProgress('Запрашиваем разрешение VPN...', percent: 10);
      await _waitForDisconnectBarrier(attemptId: attemptId, source: source);
      if (_state != SimpleVpnState.connecting) {
        _setState(SimpleVpnState.connecting);
      }
      _setConnectionProgress('Запрашиваем разрешение VPN...', percent: 10);
      final permissionOk = await _runtime.requestPermission();
      _throwIfConnectCancelled(attemptId);
      if (!permissionOk) {
        _traceConnectPhase(
          'permission_denied',
          attemptId: attemptId,
          source: source,
        );
        throw VpnPermissionException(
          'Для подключения к VPN необходимо предоставить системное разрешение.',
        );
      }
      _traceConnectPhase(
        'permission_ok',
        attemptId: attemptId,
        source: source,
      );
      networkPreflight = await _collectNetworkPreflight(source: source);
      _traceConnectPhase(
        'network_preflight_done',
        attemptId: attemptId,
        source: source,
        extra: networkPreflight,
      );
      _throwIfConnectCancelled(attemptId);

      if (_servers.isEmpty) {
        _setConnectionProgress('Выбираем оптимальный сервер...', percent: 15);
        await loadOptions();
        _throwIfConnectCancelled(attemptId);
      }
      _traceConnectPhase(
        'options_ready',
        attemptId: attemptId,
        source: source,
        extra: <String, dynamic>{
          'servers_count': _servers.length,
          'protocols_count': _protocols.length,
        },
      );
      _setConnectionProgress('Проверяем устройство...', percent: 22);
      deviceId = await _resolveDeviceId(ensureRegistered: true);
      _activeConnectDeviceId = deviceId;
      _throwIfConnectCancelled(attemptId);
      final selectedServerId = _selectedServer?.id;
      final selectedProtocolId = _selectedProtocol.id;
      _traceConnectPhase(
        'device_resolved',
        attemptId: attemptId,
        source: source,
        deviceId: deviceId,
        extra: <String, dynamic>{
          'server_id': selectedServerId,
          'protocol': selectedProtocolId,
        },
      );
      await _api.log(
        event: 'connect_tap',
        deviceId: deviceId,
        details: <String, dynamic>{
          'server_id': selectedServerId,
          'protocol': selectedProtocolId,
          'source': source,
        },
      );
      unawaited(_api.log(
        event: 'network_preflight',
        deviceId: deviceId,
        details: <String, dynamic>{
          ...networkPreflight,
          'server_id': selectedServerId,
          'protocol': selectedProtocolId,
          'source': source,
          'phase': 'before_native_start',
        },
      ).catchError((_) {}));

      await _awaitSelectedConfigWarmupIfMatching(
        serverId: selectedServerId,
        protocol: selectedProtocolId,
        deviceId: deviceId,
        attemptId: attemptId,
        source: source,
      );

      config = await _readCachedConfig(
        serverId: selectedServerId,
        protocol: selectedProtocolId,
        deviceId: deviceId,
      );
      configFromCache = config != null;
      if (configFromCache) {
        _traceConnectPhase(
          'config_cache_hit',
          attemptId: attemptId,
          source: source,
          deviceId: deviceId,
          config: config,
          extra: <String, dynamic>{'revision': config.configRevision},
        );
        _setConnectionProgress(
          'Восстанавливаем защищенный профиль...',
          percent: 36,
          badge: 'Быстрое восстановление',
        );
        unawaited(_api.log(
          event: 'config_cache_hit',
          deviceId: deviceId,
          details: <String, dynamic>{
            'server_id': selectedServerId,
            'protocol': selectedProtocolId,
            'revision': config.configRevision,
          },
        ));
      } else {
        _traceConnectPhase(
          'config_cache_miss',
          attemptId: attemptId,
          source: source,
          deviceId: deviceId,
          extra: <String, dynamic>{
            'server_id': selectedServerId,
            'protocol': selectedProtocolId,
          },
        );
        _setConnectionProgress(
          'Готовим защищенный профиль...',
          percent: 34,
          badge: 'Первичная настройка',
        );
        config = await _fetchConfigWithRetry(
          serverId: selectedServerId,
          deviceId: deviceId,
          protocol: selectedProtocolId,
          attemptId: attemptId,
          source: source,
          reason: 'cache_miss',
        );
        _traceConnectPhase(
          'config_fetch_done',
          attemptId: attemptId,
          source: source,
          deviceId: deviceId,
          config: config,
          extra: <String, dynamic>{'revision': config.configRevision},
        );
        await _writeCachedConfig(config,
            serverId: config.server?.id ?? selectedServerId,
            deviceId: deviceId);
        _throwIfConnectCancelled(attemptId);
      }

      _serverName = config.serverName;
      if (config.server != null) {
        _selectedServer = config.server;
        unawaited(_persistSelectedServerId(config.server!.id));
      }
      _throwIfConnectCancelled(attemptId);

      final useLocalFastPath = _canStartLocalConfigFastPath(
        deviceId: deviceId,
      );
      if (useLocalFastPath) {
        backendSessionDeferred = true;
        sessionId = _createRuntimeOnlySessionId(
          attemptId: attemptId,
          protocol: config.protocol,
        );
        _sessionId = sessionId;
        _activeConnectSessionId = sessionId;
        _runtimeSessionId = sessionId;
        await _persistActiveSessionId(sessionId);
        await _persistActiveRuntimeSessionId(sessionId);
        _traceConnectPhase(
          'session_start_deferred',
          attemptId: attemptId,
          source: source,
          sessionId: sessionId,
          deviceId: deviceId,
          config: config,
          extra: <String, dynamic>{
            'control_plane_mode': 'background',
            'config_from_cache': configFromCache,
            'runtime_session_id': sessionId,
          },
        );
      } else {
        _setConnectionProgress('Проверяем параметры подключения...',
            percent: 52);
        final start = await _safeStartSession(
          config.protocol,
          deviceId,
          config.server?.id ?? _selectedServer?.id,
          attemptId: attemptId,
          source: source,
          config: config,
        );
        backendSessionId = start?.sessionId;
        sessionId = _createRuntimeOnlySessionId(
          attemptId: attemptId,
          protocol: config.protocol,
        );
        _sessionId = backendSessionId;
        _activeConnectSessionId = sessionId;
        _runtimeSessionId = sessionId;
        _traceConnectPhase(
          'session_start_done',
          attemptId: attemptId,
          source: source,
          sessionId: backendSessionId,
          deviceId: deviceId,
          config: config,
          extra: <String, dynamic>{
            'runtime_session_id': sessionId,
            'control_plane_mode': 'blocking',
          },
        );
        _throwIfConnectCancelled(attemptId);
        if (backendSessionId == null || backendSessionId.isEmpty) {
          await _api.log(
            event: 'session_start_missing',
            level: 'error',
            deviceId: deviceId,
            details: <String, dynamic>{
              'protocol': config.protocol,
              'server_id': config.server?.id ?? _selectedServer?.id,
            },
          );
          throw Exception('Simple VPN session start failed');
        }
        await _persistActiveSessionId(backendSessionId);
        await _persistActiveRuntimeSessionId(sessionId);
      }
      _throwIfConnectCancelled(attemptId);

      _setConnectionProgress('Создаем защищенный туннель...', percent: 64);
      await _runtime
          .disconnect(
            reason: 'before_connect',
            source: '${source}_preconnect',
            sessionId: null,
            includeLegacy: true,
          )
          .catchError((_) => false);
      final preconnectRuntimeDown =
          await _waitForRuntimeDown(timeout: const Duration(seconds: 3));
      _traceConnectPhase(
        'preconnect_cleanup_done',
        attemptId: attemptId,
        source: source,
        sessionId: sessionId,
        deviceId: deviceId,
        config: config,
        extra: <String, dynamic>{
          'runtime_down': preconnectRuntimeDown,
        },
      );
      _throwIfConnectCancelled(attemptId);

      var ok = false;
      try {
        _setConnectionProgress('Запускаем защищенный канал...', percent: 76);
        _traceConnectPhase(
          'native_start_begin',
          attemptId: attemptId,
          source: source,
          sessionId: sessionId,
          deviceId: deviceId,
          config: config,
        );
        ok = await _runtime.startConfig(
          config,
          sessionId: sessionId,
          source: source,
        );
        _traceConnectPhase(
          'native_start_result',
          attemptId: attemptId,
          source: source,
          sessionId: sessionId,
          deviceId: deviceId,
          config: config,
          extra: <String, dynamic>{'ok': ok},
        );
        _throwIfConnectCancelled(attemptId);
      } catch (e) {
        _traceConnectPhase(
          'native_start_exception',
          attemptId: attemptId,
          source: source,
          sessionId: sessionId,
          deviceId: deviceId,
          config: config,
          extra: <String, dynamic>{
            'error': e.toString(),
            'config_from_cache': configFromCache,
          },
        );
        if (!configFromCache) rethrow;
        await _removeCachedConfig(
            serverId: selectedServerId,
            protocol: _selectedProtocol.id,
            deviceId: deviceId);
        config = await _fetchConfigWithRetry(
          serverId: selectedServerId,
          deviceId: deviceId,
          protocol: selectedProtocolId,
          attemptId: attemptId,
          source: source,
          reason: 'cached_config_start_exception',
        );
        await _writeCachedConfig(config,
            serverId: config.server?.id ?? selectedServerId,
            deviceId: deviceId);
        _throwIfConnectCancelled(attemptId);
        _serverName = config.serverName;
        if (config.server != null) {
          _selectedServer = config.server;
          unawaited(_persistSelectedServerId(config.server!.id));
        }
        _setConnectionProgress('Пробуем другой маршрут подключения...',
            percent: 72);
        _traceConnectPhase(
          'native_start_retry_begin',
          attemptId: attemptId,
          source: source,
          sessionId: sessionId,
          deviceId: deviceId,
          config: config,
          extra: <String, dynamic>{'reason': 'cached_config_start_exception'},
        );
        ok = await _runtime.startConfig(
          config,
          sessionId: sessionId,
          source: source,
        );
        _traceConnectPhase(
          'native_start_retry_result',
          attemptId: attemptId,
          source: source,
          sessionId: sessionId,
          deviceId: deviceId,
          config: config,
          extra: <String, dynamic>{'ok': ok},
        );
        _throwIfConnectCancelled(attemptId);
      }

      if (!ok && configFromCache) {
        _traceConnectPhase(
          'native_start_false_retry_prepare',
          attemptId: attemptId,
          source: source,
          sessionId: sessionId,
          deviceId: deviceId,
          config: config,
        );
        await _removeCachedConfig(
            serverId: selectedServerId,
            protocol: _selectedProtocol.id,
            deviceId: deviceId);
        config = await _fetchConfigWithRetry(
          serverId: selectedServerId,
          deviceId: deviceId,
          protocol: selectedProtocolId,
          attemptId: attemptId,
          source: source,
          reason: 'cached_config_start_false',
        );
        await _writeCachedConfig(config,
            serverId: config.server?.id ?? selectedServerId,
            deviceId: deviceId);
        _throwIfConnectCancelled(attemptId);
        _serverName = config.serverName;
        if (config.server != null) {
          _selectedServer = config.server;
          unawaited(_persistSelectedServerId(config.server!.id));
        }
        _setConnectionProgress('Пробуем оптимизировать маршрут...',
            percent: 72);
        _traceConnectPhase(
          'native_start_retry_begin',
          attemptId: attemptId,
          source: source,
          sessionId: sessionId,
          deviceId: deviceId,
          config: config,
          extra: <String, dynamic>{'reason': 'cached_config_start_false'},
        );
        ok = await _runtime.startConfig(
          config,
          sessionId: sessionId,
          source: source,
        );
        _traceConnectPhase(
          'native_start_retry_result',
          attemptId: attemptId,
          source: source,
          sessionId: sessionId,
          deviceId: deviceId,
          config: config,
          extra: <String, dynamic>{'ok': ok},
        );
        _throwIfConnectCancelled(attemptId);
      }

      if (!ok) {
        _traceConnectPhase(
          'native_start_failed_false',
          attemptId: attemptId,
          source: source,
          sessionId: sessionId,
          deviceId: deviceId,
          config: config,
        );
        throw Exception('Native VPN returned false');
      }

      _setConnectionProgress('Проверяем защищенный трафик...', percent: 92);
      _throwIfConnectCancelled(attemptId);
      final desktopDiagnostics = await _desktopVpnDiagnosticsForLogs();
      unawaited(_api.log(
        event: 'native_start_ok',
        sessionId: backendSessionId ?? sessionId,
        deviceId: deviceId,
        details: <String, dynamic>{
          'protocol': config.protocol,
          'revision': config.configRevision,
          'server': config.serverName,
          'server_id': config.server?.id ?? _selectedServer?.id,
          'engine': config.engine,
          'config_type': config.configType,
          'config_from_cache': configFromCache,
          'control_plane_mode':
              backendSessionDeferred ? 'background' : 'blocking',
          'runtime_session_id': sessionId,
          'backend_session_id': backendSessionId,
          'source': source,
          if (desktopDiagnostics.isNotEmpty)
            'desktop_vpn_diagnostics': desktopDiagnostics,
        },
      ));
      unawaited(_logRuntimeDiagnosticDump(
        phase: 'after_native_start_ok',
        source: source,
        deviceId: deviceId,
        sessionId: backendSessionId ?? sessionId,
        protocol: config.protocol,
        serverId: config.server?.id ?? _selectedServer?.id,
        serverName: config.serverName,
        includeNetworkProbe: false,
        extra: <String, dynamic>{
          'network_preflight': networkPreflight,
          ...networkPreflight,
          'config_from_cache': configFromCache,
          'control_plane_mode':
              backendSessionDeferred ? 'background' : 'blocking',
          'runtime_session_id': sessionId,
          'backend_session_id': backendSessionId,
          'engine': config.engine,
          'config_type': config.configType,
        },
      ));
      _throwIfConnectCancelled(attemptId);
      _rememberConnectedConfig(
        config: config,
        deviceId: deviceId,
        configFromCache: configFromCache,
      );
      _accessRequired = false;
      _setConnectionProgress('Соединение установлено', percent: 100);
      _traceConnectPhase(
        'connect_committed',
        attemptId: attemptId,
        source: source,
        sessionId: sessionId,
        deviceId: deviceId,
        config: config,
        extra: <String, dynamic>{
          'config_from_cache': configFromCache,
          'control_plane_mode':
              backendSessionDeferred ? 'background' : 'blocking',
          'runtime_session_id': sessionId,
          'backend_session_id': backendSessionId,
        },
      );
      _setState(SimpleVpnState.connected);
      _startEntitlementTimer();
      if (backendSessionDeferred) {
        unawaited(_startBackendSessionAfterCachedFastPath(
          config: config,
          deviceId: deviceId,
          runtimeSessionId: sessionId,
          attemptId: attemptId,
          source: source,
        ));
      } else {
        _scheduleNodeTrafficVerification();
      }
    } on SimpleVpnAccessRequiredException catch (e) {
      if (!_isCurrentConnectOwner(
        attemptId: attemptId,
        sessionId: sessionId,
      )) {
        _traceConnectPhase(
          'stale_access_required_ignored',
          attemptId: attemptId,
          source: source,
          sessionId: sessionId,
          deviceId: deviceId,
          config: config,
          extra: <String, dynamic>{
            'message': e.message,
            'current_attempt_id': _connectAttemptId,
          },
        );
        return;
      }
      _traceConnectPhase(
        'access_required',
        attemptId: attemptId,
        source: source,
        sessionId: sessionId,
        deviceId: deviceId,
        config: config,
        extra: <String, dynamic>{'message': e.message},
      );
      await _handleAccessRequired(
        source: 'connect_entitlement',
        message: e.message,
        sessionId: sessionId,
        deviceId: deviceId,
      );
      return;
    } on DeviceLimitException catch (e) {
      if (!_isCurrentConnectOwner(
        attemptId: attemptId,
        sessionId: sessionId,
      )) {
        _traceConnectPhase(
          'stale_device_limit_ignored',
          attemptId: attemptId,
          source: source,
          sessionId: sessionId,
          deviceId: deviceId,
          config: config,
          extra: <String, dynamic>{
            'limit': e.limit,
            'current_count': e.currentCount,
            'message': e.message,
            'current_attempt_id': _connectAttemptId,
          },
        );
        return;
      }
      _traceConnectPhase(
        'device_limit',
        attemptId: attemptId,
        source: source,
        sessionId: sessionId,
        deviceId: deviceId,
        config: config,
        extra: <String, dynamic>{
          'limit': e.limit,
          'current_count': e.currentCount,
          'message': e.message,
        },
      );
      _onDeviceLimit?.call(e);
      _error = null;
      _sessionId = null;
      await _clearActiveSessionId();
      _lastConnectedConfig = null;
      _lastConnectedDeviceId = null;
      _runtimeSessionId = null;
      _nodeTrafficVerifiedForSession = false;
      _clearConnectionProgress();
      _setState(SimpleVpnState.disconnected);
      await _api.log(
        event: 'device_limit_blocked',
        level: 'warning',
        sessionId: sessionId,
        deviceId: deviceId,
        details: <String, dynamic>{
          'source': source,
          'limit': e.limit,
          'current_count': e.currentCount,
          'message': e.message,
        },
      ).catchError((_) {});
      return;
    } catch (e) {
      final cancelled = e is _SimpleVpnConnectCancelled;
      if (!_isCurrentConnectOwner(
        attemptId: attemptId,
        sessionId: sessionId,
      )) {
        _traceConnectPhase(
          cancelled
              ? 'stale_connect_cancelled_ignored'
              : 'stale_connect_failed_ignored',
          attemptId: attemptId,
          source: source,
          sessionId: sessionId,
          deviceId: deviceId,
          config: config,
          extra: <String, dynamic>{
            'error': e.toString(),
            'config_from_cache': configFromCache,
            'current_attempt_id': _connectAttemptId,
          },
        );
        return;
      }
      _error = e.toString();
      _traceConnectPhase(
        cancelled ? 'connect_cancelled_exception' : 'connect_failed_exception',
        attemptId: attemptId,
        source: source,
        sessionId: sessionId,
        deviceId: deviceId,
        config: config,
        extra: <String, dynamic>{
          'error': _error,
          'config_from_cache': configFromCache,
        },
      );
      final backendSessionToStop =
          backendSessionId ?? _backendSessionId(sessionId);
      if (backendSessionToStop != null && backendSessionToStop.isNotEmpty) {
        await _api
            .stopSession(
                sessionId: backendSessionToStop,
                reason: cancelled ? 'user_cancel' : 'connect_failed',
                deviceId: deviceId)
            .catchError((_) {});
      }
      if (cancelled) {
        final runtimeSessionId = _runtimeSessionId ??
            await _readActiveRuntimeSessionId() ??
            sessionId;
        await _runtime
            .disconnect(
              reason: 'connect_cancelled',
              source: source,
              sessionId: runtimeSessionId,
            )
            .catchError((_) => false);
        await _api.log(
          event: 'connect_cancelled',
          sessionId: backendSessionToStop ?? sessionId,
          deviceId: deviceId,
          details: <String, dynamic>{
            'source': source,
            'runtime_session_id': runtimeSessionId,
            'backend_session_id': backendSessionToStop,
          },
        );
        _sessionId = null;
        await _clearActiveSessionId();
        _lastConnectedConfig = null;
        _lastConnectedDeviceId = null;
        _runtimeSessionId = null;
        _nodeTrafficVerifiedForSession = false;
        _clearConnectionProgress();
        _error = null;
        _setState(SimpleVpnState.disconnected);
        return;
      }
      final desktopDiagnostics = await _desktopVpnDiagnosticsForLogs();
      await _api.log(
        event: 'connect_failed',
        level: 'error',
        sessionId: backendSessionToStop ?? sessionId,
        deviceId: deviceId,
        details: <String, dynamic>{
          'error': _error,
          'source': source,
          'runtime_session_id': sessionId,
          'backend_session_id': backendSessionToStop,
          if (desktopDiagnostics.isNotEmpty)
            'desktop_vpn_diagnostics': desktopDiagnostics,
        },
      );
      unawaited(_logRuntimeDiagnosticDump(
        phase: 'connect_failed',
        source: source,
        deviceId: deviceId,
        sessionId: backendSessionToStop ?? sessionId,
        protocol: config?.protocol ?? _selectedProtocol.id,
        serverId: config?.server?.id ?? _selectedServer?.id,
        serverName: config?.serverName ?? _selectedServer?.name,
        level: 'error',
        includeNetworkProbe: false,
        extra: <String, dynamic>{
          'error': _error,
          'network_preflight': networkPreflight,
          ...networkPreflight,
          if (config != null) 'engine': config.engine,
          if (config != null) 'config_type': config.configType,
          'config_from_cache': configFromCache,
          'runtime_session_id': sessionId,
          'backend_session_id': backendSessionToStop,
        },
      ));
      _sessionId = null;
      await _clearActiveSessionId();
      _lastConnectedConfig = null;
      _lastConnectedDeviceId = null;
      _runtimeSessionId = null;
      _nodeTrafficVerifiedForSession = false;
      _setState(SimpleVpnState.error);
    } finally {
      if (_connectAttemptId == attemptId) {
        _activeConnectSessionId = null;
        _activeConnectDeviceId = null;
        _connectCancelRequested = false;
      }
    }
  }

  Future<void> disconnect({
    String source = 'simple_vpn',
    String reason = 'user',
  }) async {
    if (_state == SimpleVpnState.connecting) {
      await cancelConnect(source: source);
      return;
    }
    final pending = _disconnectInFlight;
    if (pending != null) {
      await pending;
      return;
    }
    final operationId = ++_disconnectOperationId;
    final operation = _performDisconnect(
      source: source,
      reason: reason,
      operationId: operationId,
    );
    _disconnectInFlight = operation;
    try {
      await operation;
    } finally {
      if (_disconnectOperationId == operationId) {
        _disconnectInFlight = null;
      }
    }
  }

  Future<void> _performDisconnect({
    required String source,
    required String reason,
    required int operationId,
  }) async {
    if (isBusy) return;
    _setState(SimpleVpnState.disconnecting);
    _clearConnectionProgress();
    _setConnectionProgress('Завершаем защищённое соединение', percent: 20);
    final sid = _sessionId ?? await _readActiveSessionId();
    final backendSid = _backendSessionId(sid);
    final runtimeSid =
        _runtimeSessionId ?? await _readActiveRuntimeSessionId() ?? sid;
    final deviceId = _lastConnectedDeviceId ?? await _resolveDeviceId();
    var nativeStopped = false;
    try {
      await _runtime.disconnect(
        reason: reason,
        source: source,
        sessionId: runtimeSid,
        includeLegacy: true,
      );
      nativeStopped = true;
      final runtimeDown = await _waitForRuntimeDown(
        timeout: _disconnectBarrierTimeout,
      );

      _sessionId = null;
      await _clearActiveSessionId();
      _lastConnectedConfig = null;
      _lastConnectedDeviceId = null;
      _runtimeSessionId = null;
      _nodeTrafficVerifiedForSession = false;
      _stopEntitlementTimer();
      _clearConnectionProgress();
      _setState(SimpleVpnState.disconnected);

      await _api
          .stopSession(
              sessionId: backendSid, reason: reason, deviceId: deviceId)
          .catchError((_) {});
      await _api.log(
        event: 'disconnect_ok',
        sessionId: backendSid ?? sid,
        deviceId: deviceId,
        details: <String, dynamic>{
          'source': source,
          'reason': reason,
          'runtime_session_id': runtimeSid,
          'backend_session_id': backendSid,
          'runtime_down': runtimeDown,
          'disconnect_operation_id': operationId,
        },
      ).catchError((_) {});
      unawaited(_logRuntimeDiagnosticDump(
        phase: 'after_disconnect_ok',
        source: source,
        deviceId: deviceId,
        sessionId: sid,
        level: 'info',
        includeNetworkProbe: true,
        extra: <String, dynamic>{'reason': reason},
      ));
    } catch (e) {
      final nativeDown =
          nativeStopped || (await _runtime.getAmneziaWgStatus()) == false;
      _sessionId = null;
      await _clearActiveSessionId();
      _lastConnectedConfig = null;
      _lastConnectedDeviceId = null;
      _runtimeSessionId = null;
      _nodeTrafficVerifiedForSession = false;
      _stopEntitlementTimer();
      _clearConnectionProgress();
      if (nativeDown) {
        unawaited(_api.log(
          event: 'disconnect_native_down_tail_failed',
          level: 'warning',
          sessionId: backendSid ?? sid,
          deviceId: deviceId,
          details: <String, dynamic>{
            'error': e.toString(),
            'source': source,
            'reason': reason,
            'runtime_session_id': runtimeSid,
            'backend_session_id': backendSid,
          },
        ));
        unawaited(_logRuntimeDiagnosticDump(
          phase: 'disconnect_native_down_tail_failed',
          source: source,
          deviceId: deviceId,
          sessionId: sid,
          level: 'warning',
          includeNetworkProbe: true,
          extra: <String, dynamic>{
            'error': e.toString(),
            'reason': reason,
          },
        ));
        _setState(SimpleVpnState.disconnected);
        return;
      }

      _error = e.toString();
      await _api.log(
        event: 'disconnect_failed',
        level: 'error',
        sessionId: backendSid ?? sid,
        deviceId: deviceId,
        details: <String, dynamic>{
          'error': _error,
          'source': source,
          'reason': reason,
          'runtime_session_id': runtimeSid,
          'backend_session_id': backendSid,
        },
      );
      unawaited(_logRuntimeDiagnosticDump(
        phase: 'disconnect_failed',
        source: source,
        deviceId: deviceId,
        sessionId: sid,
        level: 'error',
        includeNetworkProbe: true,
        extra: <String, dynamic>{
          'error': _error,
          'reason': reason,
        },
      ));
      _setState(SimpleVpnState.error);
    }
  }

  void _traceUiStateTransition(SimpleVpnState previous, SimpleVpnState next) {
    final traceId = ++_uiStateTraceSeq;
    final sessionId = _activeConnectSessionId ?? _sessionId;
    final deviceId = _activeConnectDeviceId ?? _lastConnectedDeviceId;
    final payload = <String, dynamic>{
      'trace_id': traceId,
      'from': previous.name,
      'to': next.name,
      'changed': previous != next,
      'attempt_id': _connectAttemptId,
      'session_id': sessionId,
      'device_id': deviceId,
      'protocol': _selectedProtocol.id,
      'server_id': _selectedServer?.id,
      'server_name': _selectedServer?.name,
      'progress_text': _connectionProgressText,
      'progress_percent': _connectionProgressPercent,
      'mode_badge': _connectionModeBadge,
      if (_error != null) 'error': _error,
    };
    payload.removeWhere((_, value) => value == null || value == '');
    debugPrint('[UI_STATE_TRACE] ${jsonEncode(payload)}');

    if (deviceId == null || deviceId.isEmpty) return;
    unawaited(_logUiStateTransition(
      traceId: traceId,
      previous: previous,
      next: next,
      sessionId: sessionId,
      deviceId: deviceId,
      base: payload,
    ));
  }

  Future<void> _logUiStateTransition({
    required int traceId,
    required SimpleVpnState previous,
    required SimpleVpnState next,
    required String? sessionId,
    required String deviceId,
    required Map<String, dynamic> base,
  }) async {
    try {
      bool? nativeConnected;
      bool? awgConnected;
      String? nativeError;
      String? awgError;
      try {
        nativeConnected = await _runtime
            .getNativeConnectionStatus()
            .timeout(const Duration(milliseconds: 800));
      } catch (e) {
        nativeError = e.toString();
      }
      try {
        awgConnected = await _runtime
            .getAmneziaWgStatus()
            .timeout(const Duration(milliseconds: 800));
      } catch (e) {
        awgError = e.toString();
      }
      await _api.log(
        event: 'ui_state_transition',
        level: next == SimpleVpnState.error ? 'warning' : 'info',
        sessionId: sessionId,
        deviceId: deviceId,
        details: <String, dynamic>{
          ...base,
          'trace_id': traceId,
          'native_connected': nativeConnected,
          'awg_connected': awgConnected,
          if (nativeError != null) 'native_status_error': nativeError,
          if (awgError != null) 'awg_status_error': awgError,
        },
      );
    } catch (_) {
      // Diagnostics must never affect connection lifecycle.
    }
  }

  void _setState(SimpleVpnState next) {
    final previous = _state;
    _state = next;
    if (previous != next || next == SimpleVpnState.error) {
      _traceUiStateTransition(previous, next);
    }
    if (next != SimpleVpnState.connecting &&
        next != SimpleVpnState.disconnecting) {
      _stopConnectProgressTimer();
    }
    if (next == SimpleVpnState.disconnected || next == SimpleVpnState.error) {
      if (next == SimpleVpnState.error) {
        _stopEntitlementTimer();
      }
      _connectionModeBadge = null;
      _connectionProgressPercent = null;
      if (next == SimpleVpnState.disconnected) {
        _connectionProgressText = null;
      }
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_nativeStateSubscription?.cancel());
    _nativeStateSubscription = null;
    _stopConnectProgressTimer();
    _stopEntitlementTimer();
    super.dispose();
  }
}

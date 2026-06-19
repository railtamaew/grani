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
    var stopped = await NativeVpnService.disconnectAmneziaWg(
      reason: reason,
      source: source,
      connectionSessionId: sessionId,
    );
    if (includeLegacy) {
      final legacyStopped = await NativeVpnService.disconnect(
        reason: reason,
        source: source,
        connectionSessionId: sessionId,
      ).catchError((_) => false);
      stopped = stopped || legacyStopped;
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
    if (config.engine != 'amneziawg' && config.configType != 'amneziawg') {
      throw Exception('Only GRANIwg/AmneziaWG is supported by Windows runtime');
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

class MacOSSimpleVpnRuntime implements SimpleVpnRuntime {
  const MacOSSimpleVpnRuntime();

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<bool> startConfig(
    SimpleVpnConfig config, {
    required String? sessionId,
    required String source,
  }) async {
    throw VpnUnsupportedPlatformException(
      'GRANIwg for macOS is not wired to a native tunnel runner yet. '
      'The macOS desktop build can be used for UI/auth smoke tests only.',
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
  })  : _api = api ?? SimpleVpnApi(),
        _runtime = runtime ?? createSimpleVpnRuntime(),
        _deviceIdProvider = deviceIdProvider,
        _ensureDeviceRegistered = ensureDeviceRegistered;

  static const Duration _configCacheTtl = Duration(days: 7);
  static const String _activeSessionCacheKey =
      "simple_vpn_active_session_id_v1";
  static const String _selectedServerCacheKey =
      "simple_vpn_selected_server_id_v1";
  static const String _selectedProtocolCacheKey =
      "simple_vpn_selected_protocol_id_v1";
  static const String _optionsCacheKey = "simple_vpn_options_v1";
  static const Duration _optionsCacheTtl = Duration(days: 7);

  final SimpleVpnApi _api;
  final SimpleVpnRuntime _runtime;
  final CacheService _cacheService = CacheService();
  final AnalyticsService _analyticsService = AnalyticsService();
  final Future<String?> Function()? _deviceIdProvider;
  final Future<void> Function()? _ensureDeviceRegistered;

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
  bool _connectCancelRequested = false;
  String? _activeConnectSessionId;
  String? _activeConnectDeviceId;
  Timer? _connectProgressTimer;
  Timer? _entitlementTimer;
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
    'Соединение может занять немного больше времени из-за сети.',
    'Пробуем другой маршрут подключения...',
    'Восстановление связи занимает дольше обычного — подождите, подключение продолжается.',
    'Это нормально при медленной сети, продолжаем подключение...',
    'Пробуем оптимизировать маршрут...',
    'Первичная настройка на медленной сети может занять до минуты — подождите, это нормально.',
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
    _optionsLoading = true;
    _notify();
    try {
      perf.start('simple_vpn_load_options_network');
      final results = await Future.wait<dynamic>([
        _api.fetchServers(),
        _api.fetchProtocols(),
      ]);
      perf.stop('simple_vpn_load_options_network', details: {
        'result': 'success',
      });
      _applyOptions(
        servers: results[0] as List<SimpleVpnServer>,
        protocols: results[1] as List<SimpleVpnProtocol>,
        preferredServerId: cachedServerId,
        preferredProtocolId: cachedProtocolId,
      );
      await _persistCachedOptions();
      _error = null;
    } on SimpleVpnAccessRequiredException catch (e) {
      perf.stop('simple_vpn_load_options_network', details: {
        'result': 'access_required',
      });
      await _handleAccessRequired(source: 'load_options', message: e.message);
    } catch (e) {
      perf.stop('simple_vpn_load_options_network', details: {
        'result': 'error',
        'cache_used': loadedFromCache,
        'error': e.toString(),
      });
      if (!loadedFromCache) {
        _error = e.toString();
      }
    } finally {
      _optionsLoading = false;
      perf.stop('simple_vpn_load_options_total', details: {
        'cache_used': loadedFromCache,
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
    _servers = servers;
    _protocols =
        protocols.isEmpty ? <SimpleVpnProtocol>[_selectedProtocol] : protocols;
    if (_servers.isNotEmpty) {
      final currentId = _selectedServer?.id ?? preferredServerId;
      _selectedServer = _servers.firstWhere(
        (server) => server.id == currentId,
        orElse: () => _servers.first,
      );
      unawaited(_persistSelectedServerId(_selectedServer!.id));
    }
    if (_protocols.isNotEmpty) {
      final preferredId = _isSupportedProtocolId(preferredProtocolId)
          ? preferredProtocolId
          : _selectedProtocol.id;
      _selectedProtocol = _protocols.firstWhere(
        (protocol) => protocol.id == preferredId,
        orElse: () => _protocols.first,
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

  Future<void> _persistCachedOptions() async {
    if (_servers.isEmpty) return;
    final payload = <String, dynamic>{
      'servers': _servers.map((server) => server.toJson()).toList(),
      'protocols': _protocols.map((protocol) => protocol.toJson()).toList(),
      'cached_at': DateTime.now().toIso8601String(),
    };
    await _cacheService.setString(
      _optionsCacheKey,
      jsonEncode(payload),
      ttl: _optionsCacheTtl,
    );
  }

  void selectServer(SimpleVpnServer server) {
    if (isBusy || isConnected) return;
    if (_selectedServer?.id == server.id) return;
    _selectedServer = server;
    _serverName = server.name;
    _error = null;
    unawaited(_persistSelectedServerId(server.id));
    _notify();
  }

  void selectProtocol(SimpleVpnProtocol protocol) {
    if (isBusy || isConnected) return;
    if (!_isSupportedProtocolId(protocol.id)) {
      return;
    }
    _selectedProtocol = protocol;
    _error = null;
    unawaited(_persistSelectedProtocolId(protocol.id));
    _notify();
  }

  bool _isSupportedProtocolId(String? protocolId) {
    return protocolId == 'graniwg' ||
        protocolId == 'vless_ws' ||
        protocolId == 'hysteria2';
  }

  Future<SimpleVpnStartResult?> _safeStartSession(
      String protocol, String? deviceId, int? serverId) async {
    try {
      return await _api.startSession(
          protocol: protocol, deviceId: deviceId, serverId: serverId);
    } on SimpleVpnAccessRequiredException {
      rethrow;
    } catch (_) {
      return null;
    }
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

  Future<String?> _readActiveSessionId() async {
    final cached =
        (await _cacheService.getString(_activeSessionCacheKey))?.trim();
    return cached == null || cached.isEmpty ? null : cached;
  }

  Future<void> _clearActiveSessionId() async {
    await _cacheService.remove(_activeSessionCacheKey);
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
    return _isSupportedProtocolId(cached) ? cached : null;
  }

  Future<void> _persistSelectedProtocolId(String? protocolId) async {
    if (!_isSupportedProtocolId(protocolId)) return;
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
    if (_isSupportedProtocolId(config.protocol)) {
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
        sessionId: _sessionId ?? await _readActiveSessionId(),
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
  }) async {
    _accessRequired = true;
    _error = message ?? 'Требуется активная подписка';
    _stopEntitlementTimer();
    final sid = sessionId ?? _sessionId ?? await _readActiveSessionId();
    final did = deviceId ?? _lastConnectedDeviceId;
    if (_state == SimpleVpnState.connected) {
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
    await _runtime
        .disconnect(
          reason: 'access_expired',
          source: source,
          sessionId: sid,
          includeLegacy: true,
        )
        .catchError((_) => false);
    await _api
        .stopSession(
          sessionId: sid,
          reason: 'access_expired',
          deviceId: did,
        )
        .catchError((_) {});
    unawaited(_api.log(
      event: 'access_required_disconnect',
      level: 'warning',
      sessionId: sid,
      deviceId: did,
      details: <String, dynamic>{'source': source},
    ));
    _sessionId = null;
    await _clearActiveSessionId();
    _lastConnectedConfig = null;
    _lastConnectedDeviceId = null;
    _nodeTrafficVerifiedForSession = false;
    _clearConnectionProgress();
    _setState(SimpleVpnState.disconnected);
  }

  void _scheduleNodeTrafficVerification() {
    final config = _lastConnectedConfig;
    if (config == null || _nodeVerificationInFlight) return;
    unawaited(_verifyNodeTrafficForAnalytics(
      config: config,
      sessionId: _sessionId,
      deviceId: _lastConnectedDeviceId,
      configFromCache: _lastConnectedConfigFromCache,
    ));
  }

  Future<void> _verifyNodeTrafficForAnalytics({
    required SimpleVpnConfig config,
    required String? sessionId,
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
        if (sessionId != null &&
            sessionId.isNotEmpty &&
            _sessionId != sessionId) {
          return;
        }

        try {
          final result = await _api.verifySession(
            sessionId: sessionId,
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
          };
          final hasServerSideNodeVerify = {
            'graniwg',
            'amneziawg',
            'awg',
          }.contains(config.protocol);
          details['verification_scope'] =
              hasServerSideNodeVerify ? 'server_node' : 'client_runtime';
          unawaited(_api.log(
            event: hasServerSideNodeVerify
                ? (result.verified
                    ? 'node_data_verified'
                    : 'node_data_unverified')
                : (result.verified
                    ? 'client_runtime_verified'
                    : 'client_runtime_unverified'),
            level: result.verified ? 'info' : 'warning',
            sessionId: sessionId,
            deviceId: deviceId,
            details: details,
          ));
          if (!result.verified) continue;

          if (hasServerSideNodeVerify) {
            unawaited(_api.log(
              event: 'vpn_data_verified',
              sessionId: sessionId,
              deviceId: deviceId,
              details: details,
            ));
          }
          if (hasServerSideNodeVerify && !_nodeTrafficVerifiedForSession) {
            _nodeTrafficVerifiedForSession = true;
            await _analyticsService.logVpnDataVerified(
              serverId: result.serverId ??
                  config.server?.id ??
                  _selectedServer?.id ??
                  0,
              protocol: config.protocol,
              sessionId: sessionId,
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
            sessionId: sessionId,
            deviceId: deviceId,
            details: <String, dynamic>{
              'error': e.toString(),
              'attempt': attempt + 1,
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
        _nodeTrafficVerifiedForSession = false;
        _stopEntitlementTimer();
        _setState(SimpleVpnState.disconnected);
      }
    } catch (_) {
      // Native state sync is best-effort; never block the working VPN button.
    }
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

  Future<void> cancelConnect({String source = 'simple_vpn'}) async {
    if (_state != SimpleVpnState.connecting) return;
    _connectCancelRequested = true;
    _connectAttemptId++;

    final sid = _activeConnectSessionId ?? _sessionId;
    final did = _activeConnectDeviceId ?? _lastConnectedDeviceId;
    _sessionId = null;
    await _clearActiveSessionId();
    _lastConnectedConfig = null;
    _lastConnectedDeviceId = null;
    _nodeTrafficVerifiedForSession = false;
    _clearConnectionProgress();
    _error = null;
    _setState(SimpleVpnState.disconnected);

    unawaited(_cleanupCancelledConnect(
      sessionId: sid,
      deviceId: did,
      source: source,
    ));
  }

  Future<void> _cleanupCancelledConnect({
    required String? sessionId,
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
    if (sessionId != null && sessionId.isNotEmpty) {
      await _api
          .stopSession(
            sessionId: sessionId,
            reason: 'user_cancel',
            deviceId: deviceId,
          )
          .catchError((_) {});
    }
  }

  Future<void> connect({String source = 'simple_vpn'}) async {
    if (isBusy || isConnected) return;
    final attemptId = ++_connectAttemptId;
    _connectCancelRequested = false;
    _activeConnectSessionId = null;
    _activeConnectDeviceId = null;
    _setState(SimpleVpnState.connecting);
    _error = null;
    _setConnectionProgress('Проверяем доступ...', percent: 8);
    _startConnectProgressTimer();

    String? sessionId;
    String? deviceId;
    SimpleVpnConfig? config;
    bool configFromCache = false;
    try {
      _setConnectionProgress('Запрашиваем разрешение VPN...', percent: 10);
      final permissionOk = await _runtime.requestPermission();
      _throwIfConnectCancelled(attemptId);
      if (!permissionOk) {
        throw VpnPermissionException(
          'Для подключения к VPN необходимо предоставить системное разрешение.',
        );
      }

      if (_servers.isEmpty) {
        _setConnectionProgress('Выбираем оптимальный сервер...', percent: 15);
        await loadOptions();
        _throwIfConnectCancelled(attemptId);
      }
      _setConnectionProgress('Регистрируем устройство...', percent: 22);
      deviceId = await _resolveDeviceId(ensureRegistered: true);
      _activeConnectDeviceId = deviceId;
      _throwIfConnectCancelled(attemptId);
      final selectedServerId = _selectedServer?.id;
      final selectedProtocolId = _selectedProtocol.id;
      await _api.log(
        event: 'connect_tap',
        deviceId: deviceId,
        details: <String, dynamic>{
          'server_id': selectedServerId,
          'protocol': selectedProtocolId,
          'source': source,
        },
      );

      final bypassConfigCache = selectedProtocolId == 'hysteria2';
      if (bypassConfigCache) {
        await _removeCachedConfig(
          serverId: selectedServerId,
          protocol: selectedProtocolId,
          deviceId: deviceId,
        );
      } else {
        config = await _readCachedConfig(
          serverId: selectedServerId,
          protocol: selectedProtocolId,
          deviceId: deviceId,
        );
      }
      configFromCache = config != null;
      if (configFromCache) {
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
        _setConnectionProgress(
          'Готовим защищенный профиль...',
          percent: 34,
          badge: 'Первичная настройка',
        );
        config = await _api.fetchConfig(
            serverId: selectedServerId,
            deviceId: deviceId,
            protocol: selectedProtocolId);
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

      _setConnectionProgress('Проверяем параметры подключения...', percent: 52);
      final start = await _safeStartSession(
          config.protocol, deviceId, config.server?.id ?? _selectedServer?.id);
      sessionId = start?.sessionId;
      _sessionId = sessionId;
      _activeConnectSessionId = sessionId;
      _throwIfConnectCancelled(attemptId);
      if (sessionId == null || sessionId.isEmpty) {
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
      await _persistActiveSessionId(sessionId);
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
      _throwIfConnectCancelled(attemptId);

      var ok = false;
      try {
        _setConnectionProgress('Запускаем защищенный канал...', percent: 76);
        ok = await _runtime.startConfig(
          config,
          sessionId: sessionId,
          source: source,
        );
        _throwIfConnectCancelled(attemptId);
      } catch (e) {
        if (!configFromCache) rethrow;
        await _removeCachedConfig(
            serverId: selectedServerId,
            protocol: _selectedProtocol.id,
            deviceId: deviceId);
        config = await _api.fetchConfig(
            serverId: selectedServerId,
            deviceId: deviceId,
            protocol: _selectedProtocol.id);
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
        ok = await _runtime.startConfig(
          config,
          sessionId: sessionId,
          source: source,
        );
        _throwIfConnectCancelled(attemptId);
      }

      if (!ok && configFromCache) {
        await _removeCachedConfig(
            serverId: selectedServerId,
            protocol: _selectedProtocol.id,
            deviceId: deviceId);
        config = await _api.fetchConfig(
            serverId: selectedServerId,
            deviceId: deviceId,
            protocol: _selectedProtocol.id);
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
        ok = await _runtime.startConfig(
          config,
          sessionId: sessionId,
          source: source,
        );
        _throwIfConnectCancelled(attemptId);
      }

      if (!ok) {
        throw Exception('Native VPN returned false');
      }

      _setConnectionProgress('Проверяем защищенный трафик...', percent: 92);
      _throwIfConnectCancelled(attemptId);
      unawaited(_api.log(
        event: 'native_start_ok',
        sessionId: sessionId,
        deviceId: deviceId,
        details: <String, dynamic>{
          'protocol': config.protocol,
          'revision': config.configRevision,
          'server': config.serverName,
          'server_id': config.server?.id ?? _selectedServer?.id,
          'engine': config.engine,
          'config_type': config.configType,
          'config_from_cache': configFromCache,
          'source': source,
        },
      ));
      _rememberConnectedConfig(
        config: config,
        deviceId: deviceId,
        configFromCache: configFromCache,
      );
      _accessRequired = false;
      _setConnectionProgress('Соединение установлено', percent: 100);
      _setState(SimpleVpnState.connected);
      _startEntitlementTimer();
      _scheduleNodeTrafficVerification();
    } on SimpleVpnAccessRequiredException catch (e) {
      await _handleAccessRequired(
        source: 'connect_entitlement',
        message: e.message,
        sessionId: sessionId,
        deviceId: deviceId,
      );
      return;
    } catch (e) {
      final cancelled = e is _SimpleVpnConnectCancelled;
      _error = e.toString();
      if (sessionId != null && sessionId.isNotEmpty) {
        await _api
            .stopSession(
                sessionId: sessionId,
                reason: cancelled ? 'user_cancel' : 'connect_failed',
                deviceId: deviceId)
            .catchError((_) {});
      }
      if (cancelled) {
        await _runtime
            .disconnect(
              reason: 'connect_cancelled',
              source: source,
              sessionId: sessionId,
            )
            .catchError((_) => false);
        await _api.log(
          event: 'connect_cancelled',
          sessionId: sessionId,
          deviceId: deviceId,
          details: <String, dynamic>{'source': source},
        );
        _sessionId = null;
        await _clearActiveSessionId();
        _lastConnectedConfig = null;
        _lastConnectedDeviceId = null;
        _nodeTrafficVerifiedForSession = false;
        _clearConnectionProgress();
        _error = null;
        _setState(SimpleVpnState.disconnected);
        return;
      }
      await _api.log(
        event: 'connect_failed',
        level: 'error',
        sessionId: sessionId,
        deviceId: deviceId,
        details: <String, dynamic>{'error': _error, 'source': source},
      );
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
    if (isBusy) return;
    _setState(SimpleVpnState.disconnecting);
    _clearConnectionProgress();
    _setConnectionProgress('Завершаем защищённое соединение', percent: 20);
    final sid = _sessionId ?? await _readActiveSessionId();
    final deviceId = _lastConnectedDeviceId ?? await _resolveDeviceId();
    var nativeStopped = false;
    try {
      await _runtime.disconnect(
        reason: reason,
        source: source,
        sessionId: sid,
        includeLegacy: true,
      );
      nativeStopped = true;

      _sessionId = null;
      await _clearActiveSessionId();
      _lastConnectedConfig = null;
      _lastConnectedDeviceId = null;
      _nodeTrafficVerifiedForSession = false;
      _stopEntitlementTimer();
      _clearConnectionProgress();
      _setState(SimpleVpnState.disconnected);

      await _api
          .stopSession(sessionId: sid, reason: reason, deviceId: deviceId)
          .catchError((_) {});
      await _api.log(
        event: 'disconnect_ok',
        sessionId: sid,
        deviceId: deviceId,
        details: <String, dynamic>{'source': source, 'reason': reason},
      ).catchError((_) {});
    } catch (e) {
      final nativeDown =
          nativeStopped || (await _runtime.getAmneziaWgStatus()) == false;
      _sessionId = null;
      await _clearActiveSessionId();
      _lastConnectedConfig = null;
      _lastConnectedDeviceId = null;
      _nodeTrafficVerifiedForSession = false;
      _stopEntitlementTimer();
      _clearConnectionProgress();
      if (nativeDown) {
        unawaited(_api.log(
          event: 'disconnect_native_down_tail_failed',
          level: 'warning',
          sessionId: sid,
          deviceId: deviceId,
          details: <String, dynamic>{
            'error': e.toString(),
            'source': source,
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
        sessionId: sid,
        deviceId: deviceId,
        details: <String, dynamic>{
          'error': _error,
          'source': source,
          'reason': reason,
        },
      );
      _setState(SimpleVpnState.error);
    }
  }

  void _setState(SimpleVpnState next) {
    _state = next;
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
    _stopConnectProgressTimer();
    _stopEntitlementTimer();
    super.dispose();
  }
}

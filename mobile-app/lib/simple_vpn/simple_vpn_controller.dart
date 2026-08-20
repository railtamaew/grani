// ignore_for_file: prefer_single_quotes
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../config/app_config.dart';
import '../core/cache/cache_service.dart';
import '../core/perf/perf_logger.dart';
import '../protocols/xray/models/xray_config.dart';
import '../services/native_vpn_service.dart';
import '../services/analytics_service.dart';
import '../services/activation_checklist_service.dart';
import 'simple_vpn_api.dart';
import 'simple_vpn_options_cache.dart';
import 'windows_hysteria2_config.dart';
import 'windows_split_tunnel_settings.dart';
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
      final nativeConfig = XrayConfig.fromJson(
        config.jsonConfig,
      ).toXrayNativeJsonConfig();
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
      'VPN engine ${config.engine} is not implemented in this build',
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
    // The Android coordinator owns both native/Xray/Hysteria and AmneziaWG
    // runtimes. Asking two platform channels which backend is active before
    // every stop is redundant and, on a loaded device, delayed the actual
    // teardown by several seconds. One coordinator command is authoritative
    // and also handles mixed/stale runtime state itself.
    return NativeVpnService.disconnect(
      reason: reason,
      source: source,
      connectionSessionId: sessionId,
    );
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
    final splitTunnel = await WindowsSplitTunnelSettings.load();
    if (config.engine == 'xray' || config.protocol == 'vless_ws') {
      final nativeConfig = buildWindowsVlessConfig(
        config,
        splitTunnel: splitTunnel,
      );
      return NativeVpnService.connectVless(
        nativeConfig,
        connectionSessionId: sessionId,
        source: source,
      );
    }
    if (config.engine == 'hysteria2' || config.protocol == 'hysteria2') {
      if (splitTunnel.hasRules) {
        final nativeConfig = buildWindowsHysteria2SingBoxConfig(
          config,
          splitTunnel: splitTunnel,
        );
        return NativeVpnService.connectVless(
          nativeConfig,
          connectionSessionId: sessionId,
          source: source,
        );
      }
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
    bool? requireVerifiedDataPlane,
    bool? nativeStartResultVerifiesDataPlane,
    bool subscribeNativeState = true,
  })  : _api = api ?? SimpleVpnApi(),
        _runtime = runtime ?? createSimpleVpnRuntime(),
        _deviceIdProvider = deviceIdProvider,
        _ensureDeviceRegistered = ensureDeviceRegistered,
        _onDeviceLimit = onDeviceLimit {
    _requireVerifiedDataPlane =
        requireVerifiedDataPlane ?? _runtime is AndroidSimpleVpnRuntime;
    _nativeStartResultVerifiesDataPlane = nativeStartResultVerifiesDataPlane ??
        _runtime is AndroidSimpleVpnRuntime;
    if (_runtime is WindowsSimpleVpnRuntime) {
      _selectedProtocol = _protocols.firstWhere(
        (protocol) => protocol.id == 'graniwg',
        orElse: () => _selectedProtocol,
      );
    }
    _normalizeProtocolsForRuntime();
    if (subscribeNativeState) {
      _startNativeStateSubscription();
    }
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
  static const Duration _nativeStatusTimeout = Duration(milliseconds: 800);
  static const Duration _nativeNegativeConfirmationDelay = Duration(
    milliseconds: 1200,
  );
  static const int _nativeNegativeConfirmationSamples = 3;
  static const Duration _dataPlaneReadyTimeout = Duration(seconds: 40);
  static const List<Duration> _terminalSessionRetryDelays = <Duration>[
    Duration.zero,
    Duration(milliseconds: 500),
    Duration(seconds: 2),
  ];

  final SimpleVpnApi _api;
  final SimpleVpnRuntime _runtime;
  final CacheService _cacheService = CacheService();
  final AnalyticsService _analyticsService = AnalyticsService();
  final Future<String?> Function()? _deviceIdProvider;
  final Future<void> Function()? _ensureDeviceRegistered;
  final void Function(DeviceLimitException error)? _onDeviceLimit;
  late final bool _requireVerifiedDataPlane;
  late final bool _nativeStartResultVerifiesDataPlane;
  final Map<String, Future<void>> _configWarmups = <String, Future<void>>{};

  SimpleVpnState _state = SimpleVpnState.disconnected;
  bool _initialNativeRestorePending = true;
  Future<void>? _initialNativeRestoreInFlight;
  Future<void>? _nativeUiSyncInFlight;
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
  int _lastNativeStateSequence = 0;
  bool _connectCancelRequested = false;
  Future<void>? _disconnectInFlight;
  String? _activeConnectSessionId;
  String? _activeConnectDeviceId;
  String? _runtimeSessionId;
  Completer<void>? _dataPlaneReadyCompleter;
  String? _dataPlaneReadySessionId;
  Object? _dataPlaneGateError;
  Map<String, int>? _pendingNativeTrafficProof;
  final Map<String, Future<void>> _terminalSessionOperations =
      <String, Future<void>>{};
  final Set<String> _terminatedBackendSessions = <String>{};
  DateTime? _connectedAt;
  DateTime? _firstProofAt;
  DateTime? _activeConnectStartedAt;
  String _activeConnectSource = 'simple_vpn';
  final Set<String> _reportedConnectionPhases = <String>{};
  int _lastRxBytes = 0;
  int _lastTxBytes = 0;
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
      id: 'vless_ws',
      engine: 'xray',
      status: 'planned',
      role: 'fallback',
    ),
    SimpleVpnProtocol(
      id: 'hysteria2',
      engine: 'hysteria2',
      status: 'planned',
      role: 'fallback',
    ),
    SimpleVpnProtocol(
      id: 'graniwg',
      engine: 'amneziawg',
      status: 'active',
      role: 'primary',
    ),
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
      _initialNativeRestorePending ||
      _state == SimpleVpnState.connecting ||
      _state == SimpleVpnState.disconnecting;
  bool get isRestoringNativeState => _initialNativeRestorePending;
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
    _connectProgressTimer = Timer.periodic(const Duration(seconds: 12), (
      timer,
    ) {
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

  void _prepareDataPlaneGate(String runtimeSessionId) {
    if (!_requireVerifiedDataPlane) return;
    _dataPlaneReadySessionId = runtimeSessionId;
    _dataPlaneReadyCompleter = Completer<void>();
    _dataPlaneGateError = null;
  }

  void _markDataPlaneReady(String? runtimeSessionId, {required String source}) {
    if (!_requireVerifiedDataPlane) return;
    final expected = _dataPlaneReadySessionId;
    final actual = runtimeSessionId?.trim();
    if (expected == null || expected.isEmpty) return;
    if (actual != null && actual.isNotEmpty && actual != expected) return;
    if (_dataPlaneGateError != null) return;
    final completer = _dataPlaneReadyCompleter;
    if (completer != null && !completer.isCompleted) {
      debugPrint(
        'SimpleVpnController: dataplane ready source=$source runtime_session=$expected',
      );
      completer.complete();
    }
  }

  void _failDataPlaneGate(Object error, {String? runtimeSessionId}) {
    final expected = _dataPlaneReadySessionId;
    final actual = runtimeSessionId?.trim();
    if (actual != null &&
        actual.isNotEmpty &&
        expected != null &&
        expected.isNotEmpty &&
        actual != expected) {
      return;
    }
    final completer = _dataPlaneReadyCompleter;
    if (completer != null && !completer.isCompleted) {
      _dataPlaneGateError = error;
      completer.complete();
    }
  }

  Future<void> _waitForVerifiedDataPlane(String runtimeSessionId) async {
    if (!_requireVerifiedDataPlane) return;
    if (_dataPlaneReadySessionId != runtimeSessionId) {
      throw StateError('Data-plane gate belongs to a different VPN session');
    }
    final completer = _dataPlaneReadyCompleter;
    if (completer == null) {
      throw StateError('Data-plane gate was not initialized');
    }
    await completer.future.timeout(
      _dataPlaneReadyTimeout,
      onTimeout: () => throw TimeoutException(
        'VPN runtime did not confirm protected traffic',
        _dataPlaneReadyTimeout,
      ),
    );
    final gateError = _dataPlaneGateError;
    if (gateError != null) throw gateError;
  }

  void _clearDataPlaneGate() {
    _dataPlaneReadyCompleter = null;
    _dataPlaneReadySessionId = null;
    _dataPlaneGateError = null;
  }

  Future<void> _terminateBackendSession({
    required String? sessionId,
    required String reason,
    required String? deviceId,
  }) async {
    final backendSessionId = _backendSessionId(sessionId);
    if (backendSessionId == null || backendSessionId.isEmpty) return;
    if (_terminatedBackendSessions.contains(backendSessionId)) return;
    final pending = _terminalSessionOperations[backendSessionId];
    if (pending != null) return pending;

    final operation = () async {
      Object? lastError;
      for (final delay in _terminalSessionRetryDelays) {
        if (delay > Duration.zero) await Future<void>.delayed(delay);
        try {
          await _api.stopSession(
            sessionId: backendSessionId,
            reason: reason,
            deviceId: deviceId,
          );
          if (_terminatedBackendSessions.length >= 64) {
            _terminatedBackendSessions.remove(
              _terminatedBackendSessions.first,
            );
          }
          _terminatedBackendSessions.add(backendSessionId);
          return;
        } catch (error) {
          lastError = error;
        }
      }
      debugPrint(
        'SimpleVpnController: backend session termination failed '
        'session=$backendSessionId reason=$reason error=$lastError',
      );
    }();
    _terminalSessionOperations[backendSessionId] = operation;
    try {
      await operation;
    } finally {
      if (identical(_terminalSessionOperations[backendSessionId], operation)) {
        _terminalSessionOperations.remove(backendSessionId);
      }
    }
  }

  bool _canStartLocalConfigFastPath({required String? deviceId}) {
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

  void _setConnectionProgress(String? text, {int? percent, String? badge}) {
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
    final loadedFromCache = await _loadCachedOptions(
      cachedServerId,
      cachedProtocolId,
    );
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
        perf.stop(
          'simple_vpn_load_options_network',
          details: {'result': 'empty_servers_keep_cache'},
        );
        _applyOptions(
          servers: _servers,
          protocols: protocols,
          preferredServerId: cachedServerId,
          preferredProtocolId: cachedProtocolId,
        );
        await _persistCachedOptions();
        _error = null;
        return;
      }
      if (servers.isEmpty) {
        throw StateError('Список VPN-серверов пуст');
      }
      perf.stop(
        'simple_vpn_load_options_network',
        details: {'result': 'success'},
      );
      _applyOptions(
        servers: servers,
        protocols: protocols,
        preferredServerId: cachedServerId,
        preferredProtocolId: cachedProtocolId,
      );
      await _persistCachedOptions();
      _error = null;
    } on SimpleVpnAccessRequiredException catch (e) {
      perf.stop(
        'simple_vpn_load_options_network',
        details: {'result': 'access_required'},
      );
      await _handleAccessRequired(source: 'load_options', message: e.message);
    } catch (e) {
      perf.stop(
        'simple_vpn_load_options_network',
        details: {
          'result': 'error',
          'cache_used': hasLocalOptions,
          'error': e.toString(),
        },
      );
      if (!hasLocalOptions) {
        _error = e.toString();
      }
    } finally {
      _optionsLoading = false;
      perf.stop(
        'simple_vpn_load_options_total',
        details: {
          'cache_used': hasLocalOptions,
          'options_cache_used': loadedFromCache,
          'config_cache_used': hydratedFromConfig,
          'servers': _servers.length,
          'protocols': _protocols.length,
        },
      );
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
    int? preferredServerId,
    String? preferredProtocolId,
  ) async {
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
          .map(
            (item) => SimpleVpnServer.fromJson(Map<String, dynamic>.from(item)),
          )
          .where((server) => server.id > 0)
          .toList(growable: false);
      final cachedProtocols = rawProtocols is List
          ? rawProtocols
              .whereType<Map>()
              .map(
                (item) => SimpleVpnProtocol.fromJson(
                  Map<String, dynamic>.from(item),
                ),
              )
              .where(
                (protocol) =>
                    protocol.id == 'vless_ws' ||
                    protocol.id == 'hysteria2' ||
                    protocol.id == 'graniwg',
              )
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

  /// Fetches and caches every active protocol profile while the post-auth
  /// preparation screen is already visible. This performs control-plane work
  /// only: it neither requests Android VPN permission nor starts a tunnel.
  Future<void> prewarmAvailableConfigsForPostAuth({
    String reason = 'post_auth_preparation',
  }) async {
    if (_disposed) return;
    if (_servers.isEmpty || _selectedServer == null) {
      await loadOptions();
    }
    final server = _selectedServer;
    if (_disposed || server == null) return;
    final deviceId = await _resolveDeviceId(ensureRegistered: false);
    if (deviceId == null || deviceId.isEmpty) return;

    final protocolIds = _protocols
        .where((item) =>
            item.status.toLowerCase() == 'active' &&
            _isProtocolSupportedByRuntime(item.id))
        .map((item) => item.id)
        .toSet()
        .toList(growable: false);
    if (protocolIds.isEmpty) return;

    await Future.wait<void>(
      protocolIds.map(
        (protocol) => _warmConfigForFastPath(
          serverId: server.id,
          protocol: protocol,
          deviceId: deviceId,
          reason: reason,
        ),
      ),
      eagerError: false,
    );
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
    final existing = _configWarmups[key];
    if (existing != null) return existing;
    final stopwatch = Stopwatch()..start();
    final warmup = () async {
      final cached = await _readCachedConfig(
        serverId: serverId,
        protocol: protocol,
        deviceId: deviceId,
      );
      if (cached != null || _disposed) {
        stopwatch.stop();
        if (!_disposed) {
          unawaited(
            _analyticsService.logVpnProtocolPrewarm(
              protocol: protocol,
              result: 'cache_hit',
              elapsedMs: stopwatch.elapsedMilliseconds,
              sourceSurface: reason,
            ),
          );
          unawaited(
            _api.log(
              event: 'vpn_protocol_prewarm',
              deviceId: deviceId,
              details: <String, dynamic>{
                'protocol': protocol,
                'server_id': serverId,
                'result': 'cache_hit',
                'elapsed_ms': stopwatch.elapsedMilliseconds,
                'source': reason,
              },
            ).catchError((_) {}),
          );
        }
        return;
      }
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
      stopwatch.stop();
      unawaited(
        _analyticsService.logVpnProtocolPrewarm(
          protocol: protocol,
          result: 'success',
          elapsedMs: stopwatch.elapsedMilliseconds,
          sourceSurface: reason,
        ),
      );
      unawaited(
        _api.log(
          event: 'vpn_protocol_prewarm',
          deviceId: deviceId,
          details: <String, dynamic>{
            'protocol': protocol,
            'server_id': config.server?.id ?? serverId,
            'result': 'success',
            'elapsed_ms': stopwatch.elapsedMilliseconds,
            'source': reason,
          },
        ).catchError((_) {}),
      );
    }()
        .catchError((Object e) {
      stopwatch.stop();
      debugPrint(
        'SimpleVpnController.config_warmup_failed reason=$reason $e',
      );
      if (!_disposed) {
        final failureFamily = _connectFailureFamily(e);
        unawaited(
          _analyticsService.logVpnProtocolPrewarm(
            protocol: protocol,
            result: 'failed',
            elapsedMs: stopwatch.elapsedMilliseconds,
            sourceSurface: reason,
            failureFamily: failureFamily,
          ),
        );
        unawaited(
          _api.log(
            event: 'vpn_protocol_prewarm',
            deviceId: deviceId,
            level: 'warning',
            details: <String, dynamic>{
              'protocol': protocol,
              'server_id': serverId,
              'result': 'failed',
              'failure_family': failureFamily,
              'elapsed_ms': stopwatch.elapsedMilliseconds,
              'source': reason,
            },
          ).catchError((_) {}),
        );
      }
    });
    late final Future<void> trackedWarmup;
    trackedWarmup = warmup.whenComplete(() {
      if (identical(_configWarmups[key], trackedWarmup)) {
        _configWarmups.remove(key);
      }
    });
    _configWarmups[key] = trackedWarmup;
    return trackedWarmup;
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
    final warmup = _configWarmups[key];
    if (warmup == null) return;
    _traceConnectPhase(
      'config_warmup_await',
      attemptId: attemptId,
      source: source,
      deviceId: deviceId,
      extra: <String, dynamic>{'server_id': serverId, 'protocol': protocol},
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
          protocol: protocol,
          deviceId: deviceId,
          serverId: serverId,
        );
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
      unawaited(
        _api.log(
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
        ),
      );
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
        unawaited(
          _api.log(
            event: 'background_session_start_missing',
            level: 'warning',
            sessionId: runtimeSessionId,
            deviceId: deviceId,
            details: <String, dynamic>{
              'protocol': config.protocol,
              'server_id': serverId,
              'control_plane_mode': 'background',
            },
          ),
        );
        return;
      }

      final stillCurrent = !_disposed &&
          _state == SimpleVpnState.connected &&
          _isCurrentRuntimeSession(runtimeSessionId);
      if (!stillCurrent) {
        await _terminateBackendSession(
          sessionId: backendSessionId,
          reason: 'fast_path_late_session_cleanup',
          deviceId: deviceId,
        );
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
      _flushPendingNativeTrafficProof();
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
      unawaited(
        _api.log(
          event: 'background_session_start_done',
          sessionId: backendSessionId,
          deviceId: deviceId,
          details: <String, dynamic>{
            'runtime_session_id': runtimeSessionId,
            'protocol': config.protocol,
            'server_id': serverId,
            'source': source,
          },
        ),
      );
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
      unawaited(
        _api.log(
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
        ),
      );
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
          clientCapabilities: _clientCapabilitiesForProtocol(protocol),
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
      unawaited(
        _api.log(
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
        ).catchError((_) {}),
      );
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
        lastError,
        lastStackTrace ?? StackTrace.current,
      );
    }
    throw Exception('Simple VPN config fetch failed');
  }

  String _configCacheKey({
    required int? serverId,
    required String protocol,
    required String? deviceId,
  }) {
    final resolvedServerId =
        serverId == null || serverId <= 0 ? 'default' : serverId.toString();
    final resolvedDeviceId =
        (deviceId == null || deviceId.isEmpty) ? 'default' : deviceId;
    // The Android no-obfs Hysteria profile is an explicit protocol contract,
    // not a silent replacement of the legacy Salamander profile. Give it its
    // own cache generation so an upgraded client can never reuse a v39
    // Salamander config before the backend capability request is made.
    final generation = protocol == 'hysteria2' &&
            defaultTargetPlatform == TargetPlatform.android
        ? 'v5-hy2-no-obfs-v1'
        : 'v4';
    return 'simple_vpn_config_$generation:$resolvedDeviceId:$protocol:$resolvedServerId';
  }

  String? _clientCapabilitiesForProtocol(String protocol) {
    if (protocol == 'hysteria2' &&
        defaultTargetPlatform == TargetPlatform.android) {
      return SimpleVpnApi.hysteriaNoObfsCapability;
    }
    return null;
  }

  Future<SimpleVpnConfig?> _readCachedConfig({
    required int? serverId,
    required String protocol,
    required String? deviceId,
  }) async {
    final key = _configCacheKey(
      serverId: serverId,
      protocol: protocol,
      deviceId: deviceId,
    );
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

  Future<void> _writeCachedConfig(
    SimpleVpnConfig config, {
    required int? serverId,
    required String? deviceId,
  }) async {
    final key = _configCacheKey(
      serverId: serverId,
      protocol: config.protocol,
      deviceId: deviceId,
    );
    await _cacheService.setString(
      key,
      jsonEncode(config.toJson()),
      ttl: _configCacheTtl,
    );
  }

  Future<void> _removeCachedConfig({
    required int? serverId,
    required String protocol,
    required String? deviceId,
  }) async {
    final key = _configCacheKey(
      serverId: serverId,
      protocol: protocol,
      deviceId: deviceId,
    );
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
    final cached = (await _cacheService.getString(
      _activeSessionCacheKey,
    ))
        ?.trim();
    return cached == null || cached.isEmpty ? null : cached;
  }

  Future<String?> _readActiveRuntimeSessionId() async {
    final cached = (await _cacheService.getString(
      _activeRuntimeSessionCacheKey,
    ))
        ?.trim();
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

  Future<bool> _verifyWindowsTunnelConnectivity({
    required String protocol,
    required String? sessionId,
    required String? deviceId,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      return true;
    }

    const targets = <String>[
      'https://connectivitycheck.gstatic.com/generate_204',
      'https://api.granilink.com/health',
      'https://cloudflare.com/cdn-cgi/trace',
    ];
    final failures = <String>[];
    for (var attempt = 1; attempt <= 3; attempt++) {
      for (final rawUrl in targets) {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 5)
          ..idleTimeout = const Duration(seconds: 5)
          ..userAgent = 'GRANI-Windows-connectivity-check';
        try {
          final uri = Uri.parse(rawUrl);
          final request =
              await client.getUrl(uri).timeout(const Duration(seconds: 6));
          request.followRedirects = false;
          request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
          final response = await request.close().timeout(
                const Duration(seconds: 6),
              );
          final status = response.statusCode;
          await response.drain<void>();
          if (status >= 200 && status < 500) {
            unawaited(
              _api.log(
                event: 'windows_tunnel_connectivity_verified',
                sessionId: sessionId,
                deviceId: deviceId,
                details: <String, dynamic>{
                  'protocol': protocol,
                  'attempt': attempt,
                  'target_host': uri.host,
                  'http_status': status,
                },
              ).catchError((_) {}),
            );
            return true;
          }
          failures.add('${uri.host}:http_$status');
        } catch (error) {
          final host = Uri.tryParse(rawUrl)?.host ?? 'invalid_target';
          failures.add('$host:${error.runtimeType}');
        } finally {
          client.close(force: true);
        }
      }
      if (attempt < 3) {
        await Future<void>.delayed(Duration(seconds: attempt));
      }
    }

    unawaited(
      _api.log(
        event: 'windows_tunnel_connectivity_failed',
        level: 'error',
        sessionId: sessionId,
        deviceId: deviceId,
        details: <String, dynamic>{
          'protocol': protocol,
          'attempts': 3,
          'failures': failures.take(12).toList(growable: false),
        },
      ).catchError((_) {}),
    );
    return false;
  }

  Future<int?> _readSelectedServerId() async {
    final cached = (await _cacheService.getString(
      _selectedServerCacheKey,
    ))
        ?.trim();
    if (cached == null || cached.isEmpty) return null;
    return int.tryParse(cached);
  }

  Future<void> _persistSelectedServerId(int? serverId) async {
    if (serverId == null || serverId <= 0) return;
    await _cacheService.setString(_selectedServerCacheKey, serverId.toString());
  }

  Future<String?> _readSelectedProtocolId() async {
    final cached = (await _cacheService.getString(
      _selectedProtocolCacheKey,
    ))
        ?.trim();
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

  Future<void> _checkEntitlementWhileConnected({
    String source = 'verify',
  }) async {
    if (_disposed || _state != SimpleVpnState.connected) return;
    try {
      await _api.verifySession(
        sessionId: _backendSessionId(
          _sessionId ?? await _readActiveSessionId(),
        ),
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
      unawaited(
        _api.log(
          event: 'access_required_stop_suppressed',
          level: 'warning',
          sessionId: sid,
          deviceId: did,
          details: <String, dynamic>{
            'source': source,
            'reason': 'subscription_required',
            'policy': 'keep_tunnel_until_explicit_stop',
          },
        ),
      );
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
    await _terminateBackendSession(
      sessionId: backendSid,
      reason: disconnectReason,
      deviceId: did,
    );
    if (isDeviceLimit) {
      _onDeviceLimit?.call(
        deviceLimit ??
            DeviceLimitException(message ?? 'Превышен лимит устройств'),
      );
    }
    unawaited(
      _api.log(
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
      ),
    );
    _sessionId = null;
    await _clearActiveSessionId();
    _lastConnectedConfig = null;
    _lastConnectedDeviceId = null;
    _runtimeSessionId = null;
    _nodeTrafficVerifiedForSession = false;
    _pendingNativeTrafficProof = null;
    _clearDataPlaneGate();
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
    final analyticsSessionId = backendSessionId ??
        ((runtimeSessionId != null && runtimeSessionId.isNotEmpty)
            ? runtimeSessionId
            : null);
    if (analyticsSessionId == null || analyticsSessionId.isEmpty) return;
    unawaited(
      _verifyNodeTrafficForAnalytics(
        config: config,
        analyticsSessionId: analyticsSessionId,
        runtimeSessionId: runtimeSessionId,
        backendSessionId: backendSessionId,
        deviceId: _lastConnectedDeviceId,
        configFromCache: _lastConnectedConfigFromCache,
      ),
    );
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
          unawaited(
            _api.log(
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
            ),
          );
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
          unawaited(
            _api.log(
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
            ),
          );
        }
      }
    } finally {
      _nodeVerificationInFlight = false;
    }
  }

  Future<bool?> _readNativeConnectedStatus() async {
    bool? amneziaWgConnected;
    bool? nativeConnected;
    try {
      amneziaWgConnected = await _runtime.getAmneziaWgStatus().timeout(
            _nativeStatusTimeout,
            onTimeout: () => null,
          );
    } catch (_) {}
    try {
      nativeConnected = await _runtime.getNativeConnectionStatus().timeout(
            _nativeStatusTimeout,
            onTimeout: () => null,
          );
    } catch (_) {}

    if (amneziaWgConnected == true || nativeConnected == true) return true;
    if (amneziaWgConnected == false && nativeConnected == false) return false;
    return null;
  }

  Future<bool?> _readStableNativeConnectedStatus() async {
    final first = await _readNativeConnectedStatus();
    if (first != false) return first;
    if (await _nativeDiagnosticsShowActiveTunnel()) {
      return true;
    }
    final protectCommittedTunnel = _state == SimpleVpnState.connected ||
        _state == SimpleVpnState.disconnecting ||
        (_runtimeSessionId?.isNotEmpty ?? false) ||
        (_sessionId?.isNotEmpty ?? false);
    if (!protectCommittedTunnel) return false;
    for (var sample = 1;
        sample < _nativeNegativeConfirmationSamples;
        sample += 1) {
      await Future<void>.delayed(_nativeNegativeConfirmationDelay);
      final next = await _readNativeConnectedStatus();
      if (next != false) return next;
      if (protectCommittedTunnel &&
          await _nativeDiagnosticsShowActiveTunnel()) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _nativeDiagnosticsShowActiveTunnel() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      final diagnostics =
          await NativeVpnService.getRuntimeDiagnostics().timeout(
        _nativeStatusTimeout,
        onTimeout: () => null,
      );
      if (diagnostics == null) return false;
      return diagnostics['grani_likely_active'] == true ||
          diagnostics['awg_runner_up'] == true ||
          diagnostics['native_active_or_closing'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> restoreInitialNativeState({
    String source = 'initial_native_restore',
  }) async {
    final pending = _initialNativeRestoreInFlight;
    if (pending != null) {
      await pending;
      return;
    }
    final operation = _performInitialNativeRestore(source: source);
    _initialNativeRestoreInFlight = operation;
    try {
      await operation;
    } finally {
      if (identical(_initialNativeRestoreInFlight, operation)) {
        _initialNativeRestoreInFlight = null;
      }
    }
  }

  Future<void> _performInitialNativeRestore({required String source}) async {
    _initialNativeRestorePending = true;
    _setConnectionProgress('Проверяем параметры подключения...', percent: 6);
    unawaited(
      _api.log(
        event: 'vpn_state_restore_started',
        sessionId: _sessionId,
        details: <String, dynamic>{'source': source},
      ),
    );

    bool? connected;
    try {
      connected = await _readStableNativeConnectedStatus();
      if (connected == true) {
        await _adoptNativeConnectedEvent(source: source);
        _scheduleNodeTrafficVerification();
        unawaited(_checkEntitlementWhileConnected(source: source));
      } else if (connected == false && _state == SimpleVpnState.connected) {
        await _adoptNativeDisconnectedEvent(source: source);
      }
    } finally {
      _initialNativeRestorePending = false;
      _clearConnectionProgress();
      _notify();
      unawaited(
        _api.log(
          event: 'vpn_state_restore_completed',
          sessionId: _sessionId,
          details: <String, dynamic>{
            'source': source,
            'native_connected': connected,
            'ui_state': _state.name,
          },
        ),
      );
      unawaited(
        _logRuntimeDiagnosticDump(
          phase: 'native_state_restore',
          source: source,
          deviceId: _lastConnectedDeviceId,
          sessionId: _sessionId,
          includeNetworkProbe: false,
          extra: <String, dynamic>{
            'native_connected': connected,
            'ui_state': _state.name,
          },
        ),
      );
    }
  }

  Future<void> syncNativeState({String source = 'native_sync'}) async {
    if (_state == SimpleVpnState.connecting ||
        _state == SimpleVpnState.disconnecting) {
      return;
    }
    try {
      final connected = await _readStableNativeConnectedStatus();
      if (connected == true) {
        await _adoptNativeConnectedEvent(source: source);
        _scheduleNodeTrafficVerification();
        unawaited(_checkEntitlementWhileConnected(source: source));
      } else if (connected == false && _state == SimpleVpnState.connected) {
        await _adoptNativeDisconnectedEvent(source: source);
      }
    } catch (_) {
      // Native state sync is best-effort; never block the working VPN button.
    }
  }

  Future<void> syncNativeUiState({String source = 'native_ui_sync'}) async {
    final pending = _nativeUiSyncInFlight;
    if (pending != null) {
      await pending;
      return;
    }
    final operation = _performNativeUiStateSync(source: source);
    _nativeUiSyncInFlight = operation;
    try {
      await operation;
    } finally {
      if (identical(_nativeUiSyncInFlight, operation)) {
        _nativeUiSyncInFlight = null;
      }
    }
  }

  Future<void> _performNativeUiStateSync({required String source}) async {
    try {
      final connected = await _readStableNativeConnectedStatus();
      if (connected == true) {
        // Polling is only a restore/reconciliation fallback. It must never
        // complete an in-flight connection: only verified native state or the
        // verified native start result may open the data-plane gate.
        if (_state != SimpleVpnState.connecting &&
            _state != SimpleVpnState.disconnecting) {
          await _adoptNativeConnectedEvent(source: source);
        }
      } else if (connected == false) {
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

    final eventSequence =
        int.tryParse(event['runtime_sequence']?.toString() ?? '') ?? 0;
    if (eventSequence > 0 && eventSequence < _lastNativeStateSequence) {
      _traceNativeStateEvent(
        event,
        decision: 'ignored',
        reason: 'out_of_order_sequence',
      );
      return;
    }
    if (eventSequence > _lastNativeStateSequence) {
      _lastNativeStateSequence = eventSequence;
    }

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
        'SimpleVpnController: ignore stale native event service_state=$serviceState event_session=$eventSessionId expected_session=$expectedSessionId',
      );
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
        'SimpleVpnController: ignore sessionless native stop while connecting service_state=$serviceState',
      );
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
        'SimpleVpnController: ignore sessionless native stop tail service_state=$serviceState expected_session=$expectedSessionId',
      );
      return;
    }
    final runtimeError = event['runtime_error']?.toString().trim();
    final dataPlaneVerified =
        serviceState == 'dataplane_verified' || serviceState == 'committed';
    // A legacy/sessionless "connected" edge can be emitted while the native
    // service is only LOCAL_UP. It may restore an already running tunnel, but
    // must not complete an in-flight connection before verified traffic.
    final legacyConnected = event['connected'] == true &&
        serviceState.isEmpty &&
        _state != SimpleVpnState.connecting;

    if (serviceState == 'local_up') {
      _logConnectionPhaseIfNeeded('local_up');
      _traceNativeStateEvent(event, decision: 'local_up_waiting_for_dataplane');
      if (_state == SimpleVpnState.connecting) {
        _setConnectionProgress(
          'Проверяем защищенный трафик...',
          percent: 92,
        );
      }
      return;
    }

    if (dataPlaneVerified) {
      _logConnectionPhaseIfNeeded('dataplane_verified');
      _markDataPlaneReady(
        eventSessionId.isEmpty ? expectedSessionId : eventSessionId,
        source: 'native_state_$serviceState',
      );
      if (_state == SimpleVpnState.connecting) {
        _traceNativeStateEvent(event, decision: 'dataplane_gate_completed');
        return;
      }
    }

    if (dataPlaneVerified || legacyConnected) {
      if (_state == SimpleVpnState.disconnecting) {
        _traceNativeStateEvent(
          event,
          decision: 'ignored',
          reason: 'connected_while_disconnecting',
        );
        debugPrint(
          'SimpleVpnController: ignore native connected event while disconnecting service_state=$serviceState',
        );
        return;
      }
      _traceNativeStateEvent(event, decision: 'adopt_connected');
      unawaited(
        _adoptNativeConnectedEvent(source: 'native_event_$serviceState'),
      );
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
        _failDataPlaneGate(
          StateError('VPN runtime disconnected before traffic verification'),
          runtimeSessionId: eventSessionId,
        );
        if (_state == SimpleVpnState.connected ||
            _state == SimpleVpnState.connecting) {
          _setState(SimpleVpnState.disconnecting);
        }
        break;
      case 'idle':
        _traceNativeStateEvent(event, decision: 'confirm_disconnected');
        _failDataPlaneGate(
          StateError('VPN runtime stopped before traffic verification'),
          runtimeSessionId: eventSessionId,
        );
        unawaited(syncNativeUiState(source: 'native_event_idle_confirmation'));
        break;
      case 'error':
        _traceNativeStateEvent(event, decision: 'error');
        _failDataPlaneGate(
          StateError(runtimeError ?? 'VPN runtime error'),
          runtimeSessionId: eventSessionId,
        );
        _error ??= runtimeError != null && runtimeError.isNotEmpty
            ? runtimeError
            : 'VPN runtime error';
        final backendSessionId = _backendSessionId(_sessionId);
        final deviceId = _lastConnectedDeviceId ?? _activeConnectDeviceId;
        unawaited(
          _terminateBackendSession(
            sessionId: backendSessionId,
            reason: 'native_runtime_error',
            deviceId: deviceId,
          ),
        );
        _setState(SimpleVpnState.error);
        break;
    }
  }

  void _logConnectionPhaseIfNeeded(String phase) {
    final startedAt = _activeConnectStartedAt;
    if (startedAt == null || !_reportedConnectionPhases.add(phase)) return;
    final elapsedMs =
        DateTime.now().difference(startedAt).inMilliseconds.clamp(0, 1 << 31);
    unawaited(
      _analyticsService.logVpnConnectionPhase(
        phase: phase,
        elapsedMs: elapsedMs,
        protocol: _lastConnectedConfig?.protocol ?? _selectedProtocol.id,
        sourceSurface: _activeConnectSource,
        connectionSessionId: _currentNativeRuntimeSessionId(),
      ),
    );
  }

  @visibleForTesting
  void handleNativeStateForTesting(Map<dynamic, dynamic> event) {
    _handleNativeStateEvent(event);
  }

  int _nativeTrafficCounter(Map<dynamic, dynamic> event, String key) {
    final value = event[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  void _handleNativeTrafficProof(Map<dynamic, dynamic> event) {
    if (_disposed ||
        (_state != SimpleVpnState.connecting &&
            _state != SimpleVpnState.connected) ||
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

    _pendingNativeTrafficProof = <String, int>{
      'rx_bytes': rxBytes,
      'tx_bytes': txBytes,
    };
    _flushPendingNativeTrafficProof();
  }

  void _flushPendingNativeTrafficProof() {
    if (_disposed || _nodeTrafficVerifiedForSession) {
      return;
    }
    final proof = _pendingNativeTrafficProof;
    final backendSessionId = _backendSessionId(_sessionId);
    final config = _lastConnectedConfig;
    final deviceId = _lastConnectedDeviceId;
    if (proof == null ||
        backendSessionId == null ||
        backendSessionId.isEmpty ||
        config == null ||
        deviceId == null ||
        deviceId.isEmpty) {
      return;
    }

    final runtimeSessionId = _currentNativeRuntimeSessionId();
    final rxBytes = proof['rx_bytes'] ?? 0;
    final txBytes = proof['tx_bytes'] ?? 0;
    _pendingNativeTrafficProof = null;
    _nodeTrafficVerifiedForSession = true;
    _lastRxBytes = rxBytes;
    _lastTxBytes = txBytes;
    _firstProofAt ??= DateTime.now().toUtc();
    unawaited(ActivationChecklistService.markFirstProofAndShow());
    final serverId = config.server?.id ?? _selectedServer?.id ?? 0;
    unawaited(
      _api.log(
        event: 'vpn_data_verified',
        sessionId: backendSessionId,
        deviceId: deviceId,
        details: <String, dynamic>{
          'server_id': serverId,
          'protocol': config.protocol,
          'rx_bytes': rxBytes,
          'tx_bytes': txBytes,
          'runtime_session_id': runtimeSessionId,
          'backend_session_id': backendSessionId,
          'connection_session_id': backendSessionId,
          'vpn_session_id': backendSessionId,
          'verification_scope': 'client_tun',
          'verification_source': 'native_tun_counters',
          'node_verified': false,
        },
      ),
    );
    unawaited(
      _analyticsService.logVpnDataVerified(
        serverId: serverId,
        protocol: config.protocol,
        sessionId: backendSessionId,
        rxBytes: rxBytes,
        txBytes: txBytes,
        fromCache: _lastConnectedConfigFromCache,
      ),
    );
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
    final wasUnexpected = _state == SimpleVpnState.connected &&
        _disconnectInFlight == null &&
        !_connectCancelRequested;
    final backendSessionId = _backendSessionId(
      _sessionId ?? await _readActiveSessionId(),
    );
    final deviceId = _lastConnectedDeviceId ?? _activeConnectDeviceId;
    if (wasUnexpected) {
      final protocol = _lastConnectedConfig?.protocol ?? _selectedProtocol.id;
      final sessionAge = _connectedAt == null
          ? null
          : DateTime.now().difference(_connectedAt!);
      final details = <String, dynamic>{
        'protocol': protocol,
        'disconnect_source': source,
        'lifecycle_state':
            WidgetsBinding.instance.lifecycleState?.name ?? 'unknown',
        'session_age_bucket': _sessionAgeBucket(sessionAge),
        'had_verified_traffic': _nodeTrafficVerifiedForSession,
      };
      unawaited(
        _api
            .log(
              event: 'vpn_unexpected_disconnect',
              sessionId: backendSessionId,
              deviceId: deviceId,
              level: 'warning',
              details: details,
            )
            .catchError((_) {}),
      );
      unawaited(
        _analyticsService.logVpnUnexpectedDisconnect(
          protocol: protocol,
          disconnectSource: source,
          lifecycleState: details['lifecycle_state']! as String,
          sessionAgeBucket: details['session_age_bucket']! as String,
          hadVerifiedTraffic: _nodeTrafficVerifiedForSession,
        ),
      );
      unawaited(
        _logRuntimeDiagnosticDump(
          phase: 'unexpected_disconnect',
          source: source,
          protocol: protocol,
          deviceId: deviceId,
          sessionId: backendSessionId,
          includeNetworkProbe: true,
          extra: details,
        ),
      );
    }
    _failDataPlaneGate(StateError('Native VPN disconnected'));
    unawaited(
      _terminateBackendSession(
        sessionId: backendSessionId,
        reason: 'native_disconnected_$source',
        deviceId: deviceId,
      ),
    );
    _sessionId = null;
    await _clearActiveSessionId();
    if (_disposed) return;
    _lastConnectedConfig = null;
    _lastConnectedDeviceId = null;
    _lastConnectedConfigFromCache = false;
    _runtimeSessionId = null;
    _nodeTrafficVerifiedForSession = false;
    _pendingNativeTrafficProof = null;
    _clearDataPlaneGate();
    _stopEntitlementTimer();
    _error = null;
    _setState(SimpleVpnState.disconnected);
  }

  String _sessionAgeBucket(Duration? age) {
    if (age == null || age.isNegative) return 'unknown';
    if (age < const Duration(seconds: 30)) return 'lt_30s';
    if (age < const Duration(minutes: 2)) return '30s_2m';
    if (age < const Duration(minutes: 10)) return '2m_10m';
    if (age < const Duration(hours: 1)) return '10m_1h';
    return 'gte_1h';
  }

  Future<void> toggle({String source = 'simple_vpn'}) async {
    if (_initialNativeRestorePending) {
      unawaited(
        _api.log(
          event: 'vpn_tap_blocked_while_restoring',
          sessionId: _sessionId,
          details: <String, dynamic>{'source': source},
        ),
      );
      await restoreInitialNativeState(source: '${source}_tap_restore');
      return;
    }
    if (_state == SimpleVpnState.connecting) {
      await cancelConnect(source: source);
      return;
    }
    if (isBusy) return;
    final wasConnected = isConnected;
    await syncNativeUiState(source: '${source}_tap_preflight');
    if (!wasConnected && isConnected) {
      unawaited(
        _api.log(
          event: 'vpn_existing_session_adopted',
          sessionId: _sessionId,
          details: <String, dynamic>{'source': source, 'phase': 'tap'},
        ),
      );
      return;
    }
    if (wasConnected && !isConnected) return;
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

  bool _isCurrentConnectOwner({required int attemptId, String? sessionId}) {
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
    _pendingNativeTrafficProof = null;
    _clearDataPlaneGate();
    _clearConnectionProgress();
    _error = null;
    _setState(SimpleVpnState.disconnected);

    unawaited(
      _cleanupCancelledConnect(
        sessionId: runtimeSid,
        backendSessionId: backendSid,
        deviceId: did,
        source: source,
      ),
    );
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
      await _terminateBackendSession(
        sessionId: backendSid,
        reason: 'user_cancel',
        deviceId: deviceId,
      );
    }
    await _api.log(
      event: 'connect_cancelled',
      sessionId: backendSid ?? sessionId,
      deviceId: deviceId,
      details: <String, dynamic>{
        'source': source,
        'runtime_session_id': sessionId,
        'backend_session_id': backendSid,
      },
    ).catchError((_) {});
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
      'runtime_sequence': event['runtime_sequence'],
      'runtime_updated_at_ms': event['runtime_updated_at_ms'],
      'last_accepted_runtime_sequence': _lastNativeStateSequence,
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
      nativeConnected = await _runtime.getNativeConnectionStatus().timeout(
            _runtimeDownStatusTimeout,
          );
    } catch (_) {
      nativeConnected = null;
    }
    try {
      awgConnected = await _runtime.getAmneziaWgStatus().timeout(
            _runtimeDownStatusTimeout,
          );
    } catch (_) {
      awgConnected = null;
    }
    return nativeConnected == false && awgConnected == false;
  }

  Future<bool> _waitForRuntimeDown({required Duration timeout}) async {
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
      final nativeActiveOrClosing = _diagnosticBool(
        dump['native_active_or_closing'],
      );
      final androidSystemVpnActive = _diagnosticBool(
        dump['android_system_vpn_active'],
      );
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

  String _connectFailureFamily(Object error) {
    if (error is _SimpleVpnConnectCancelled) return 'cancelled';
    if (error is VpnPermissionException) return 'permission_denied';
    if (error is SimpleVpnAccessRequiredException) return 'access_required';
    if (error is DeviceLimitException) return 'device_limit';
    if (error is TimeoutException) return 'timeout';
    if (error is SocketException) return 'network';

    final message = error.toString().toLowerCase();
    if (message.contains('401') ||
        message.contains('unauthorized') ||
        message.contains('token')) {
      return 'authentication';
    }
    if (message.contains('timeout') || message.contains('timed out')) {
      return 'timeout';
    }
    if (message.contains('network') ||
        message.contains('socket') ||
        message.contains('internet')) {
      return 'network';
    }
    if (message.contains('config')) return 'configuration';
    if (message.contains('native vpn returned false')) return 'native_start';
    return 'unknown';
  }

  bool _isTerminalNativeStartTimeout(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('vpn_timeout') ||
        message.contains('start_timeout') ||
        message.contains('не вышел в committed');
  }

  Future<void> connect({String source = 'simple_vpn'}) async {
    if (_initialNativeRestorePending) {
      await restoreInitialNativeState(source: '${source}_connect_restore');
      if (isConnected) return;
    }
    if (_state == SimpleVpnState.connecting || isConnected) return;
    if (_state == SimpleVpnState.disconnecting && _disconnectInFlight == null) {
      return;
    }
    final nativeConnected = await _readStableNativeConnectedStatus();
    if (nativeConnected == true) {
      await _adoptNativeConnectedEvent(source: '${source}_connect_preflight');
      unawaited(
        _api.log(
          event: 'vpn_existing_session_adopted',
          sessionId: _sessionId,
          details: <String, dynamic>{'source': source, 'phase': 'connect'},
        ),
      );
      return;
    }
    if (nativeConnected == null) {
      unawaited(
        _api.log(
          event: 'vpn_connect_deferred_native_state_unknown',
          level: 'warning',
          sessionId: _sessionId,
          details: <String, dynamic>{'source': source},
        ),
      );
      return;
    }
    final attemptId = ++_connectAttemptId;
    final attemptSessionId = _createRuntimeOnlySessionId(
      attemptId: attemptId,
      protocol: _selectedProtocol.id,
    );
    _connectCancelRequested = false;
    _activeConnectSessionId = attemptSessionId;
    _activeConnectStartedAt = DateTime.now();
    _activeConnectSource = source;
    _reportedConnectionPhases.clear();
    _activeConnectDeviceId = null;
    _runtimeSessionId = attemptSessionId;
    _prepareDataPlaneGate(attemptSessionId);
    _pendingNativeTrafficProof = null;
    _connectedAt = null;
    _firstProofAt = null;
    _lastRxBytes = 0;
    _lastTxBytes = 0;
    _setState(SimpleVpnState.connecting);
    _error = null;
    _setConnectionProgress('Проверяем доступ...', percent: 8);
    _startConnectProgressTimer();
    _traceConnectPhase(
      'connect_begin',
      attemptId: attemptId,
      source: source,
      extra: <String, dynamic>{
        'verified_dataplane_required': _requireVerifiedDataPlane,
      },
    );
    unawaited(
      _analyticsService.logConnectTap(
        sourceSurface: source,
        protocol: _selectedProtocol.id,
        connectionSessionId: attemptSessionId,
      ),
    );

    String? sessionId = attemptSessionId;
    String? backendSessionId;
    String? deviceId;
    SimpleVpnConfig? config;
    bool configFromCache = false;
    bool backendSessionDeferred = false;
    var networkPreflight = <String, dynamic>{};
    Future<Map<String, dynamic>>? networkPreflightFuture;
    final analyticsStopwatch = Stopwatch()..start();
    var analyticsStage = 'permission';
    var analyticsResultLogged = false;

    void logConnectResult({required String result, String? errorFamily}) {
      if (analyticsResultLogged) return;
      analyticsResultLogged = true;
      analyticsStopwatch.stop();
      unawaited(
        _analyticsService.logVpnConnectResult(
          result: result,
          failureStage: analyticsStage,
          elapsedMs: analyticsStopwatch.elapsedMilliseconds,
          protocol: config?.protocol ?? _selectedProtocol.id,
          sourceSurface: source,
          serverId: config?.server?.id ?? _selectedServer?.id ?? 0,
          connectionSessionId: attemptSessionId,
          errorFamily: errorFamily,
        ),
      );
    }

    try {
      _setConnectionProgress('Запрашиваем разрешение VPN...', percent: 10);
      await _waitForDisconnectBarrier(attemptId: attemptId, source: source);
      if (_state != SimpleVpnState.connecting) {
        _setState(SimpleVpnState.connecting);
      }
      _setConnectionProgress('Запрашиваем разрешение VPN...', percent: 10);
      final permissionPromptShown =
          Platform.isAndroid && await NativeVpnService.isPermissionRequired();
      if (permissionPromptShown) {
        unawaited(
          _analyticsService.logVpnPermissionShown(
            sourceSurface: source,
            connectionSessionId: attemptSessionId,
          ),
        );
      }
      late final bool permissionOk;
      try {
        permissionOk = await _runtime.requestPermission();
      } catch (_) {
        if (permissionPromptShown) {
          unawaited(
            _analyticsService.logVpnPermissionResult(
              granted: false,
              sourceSurface: source,
              promptShown: true,
              connectionSessionId: attemptSessionId,
            ),
          );
        }
        rethrow;
      }
      if (permissionPromptShown) {
        unawaited(
          _analyticsService.logVpnPermissionResult(
            granted: permissionOk,
            sourceSurface: source,
            promptShown: true,
            connectionSessionId: attemptSessionId,
          ),
        );
      }
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
      _traceConnectPhase('permission_ok', attemptId: attemptId, source: source);
      analyticsStage = 'network_preflight';
      // This probe is diagnostic-only. Running it in the critical path added
      // roughly one second to every connection even though its result never
      // allows or blocks the VPN start. Preserve the telemetry, but collect it
      // concurrently with device/config preparation.
      networkPreflightFuture = _collectNetworkPreflight(source: source);
      unawaited(
        networkPreflightFuture.then<void>((result) {
          networkPreflight = result;
          _traceConnectPhase(
            'network_preflight_done',
            attemptId: attemptId,
            source: source,
            extra: result,
          );
        }),
      );
      _throwIfConnectCancelled(attemptId);

      if (_servers.isEmpty) {
        analyticsStage = 'options';
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
      analyticsStage = 'device';
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
      unawaited(
        _analyticsService.logVpnConnectStart(
          serverId: selectedServerId ?? 0,
          protocol: selectedProtocolId,
          sourceSurface: source,
          connectionSessionId: attemptSessionId,
        ),
      );
      unawaited(
        _api.log(
          event: 'connect_tap',
          sessionId: attemptSessionId,
          deviceId: deviceId,
          details: <String, dynamic>{
            'server_id': selectedServerId,
            'protocol': selectedProtocolId,
            'source': source,
            'runtime_session_id': attemptSessionId,
            'connection_session_id': attemptSessionId,
            'vpn_session_id': attemptSessionId,
            'app_version': AppConfig.appVersion,
            'build_number': AppConfig.buildNumber,
            'full_version': AppConfig.getFullVersion(),
          },
        ).catchError((_) {}),
      );
      unawaited(
        (() async {
          final preflight = await networkPreflightFuture!;
          await _api.log(
            event: 'network_preflight',
            sessionId: attemptSessionId,
            deviceId: deviceId,
            details: <String, dynamic>{
              ...preflight,
              'server_id': selectedServerId,
              'protocol': selectedProtocolId,
              'source': source,
              'phase': 'before_native_start',
              'runtime_session_id': attemptSessionId,
              'app_version': AppConfig.appVersion,
              'build_number': AppConfig.buildNumber,
            },
          );
        })()
            .catchError((_) {}),
      );

      analyticsStage = 'config';
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
        unawaited(
          _api.log(
            event: 'config_cache_hit',
            deviceId: deviceId,
            details: <String, dynamic>{
              'server_id': selectedServerId,
              'protocol': selectedProtocolId,
              'revision': config.configRevision,
            },
          ),
        );
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
        await _writeCachedConfig(
          config,
          serverId: config.server?.id ?? selectedServerId,
          deviceId: deviceId,
        );
        _throwIfConnectCancelled(attemptId);
      }

      _serverName = config.serverName;
      if (config.server != null) {
        _selectedServer = config.server;
        unawaited(_persistSelectedServerId(config.server!.id));
      }
      _throwIfConnectCancelled(attemptId);

      final useLocalFastPath = _canStartLocalConfigFastPath(deviceId: deviceId);
      analyticsStage = 'backend_session';
      if (useLocalFastPath) {
        backendSessionDeferred = true;
        sessionId = attemptSessionId;
        _sessionId = sessionId;
        _activeConnectSessionId = sessionId;
        _runtimeSessionId = sessionId;
        // Persist in parallel with native startup. The runtime receives the
        // same session id directly, so synchronous disk fsync must not delay
        // opening the tunnel; the writes still complete in this isolate.
        unawaited(
          (() async {
            try {
              await Future.wait<void>(<Future<void>>[
                _persistActiveSessionId(attemptSessionId),
                _persistActiveRuntimeSessionId(attemptSessionId),
              ]);
            } catch (_) {}
          })(),
        );
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
        _setConnectionProgress(
          'Проверяем параметры подключения...',
          percent: 52,
        );
        final start = await _safeStartSession(
          config.protocol,
          deviceId,
          config.server?.id ?? _selectedServer?.id,
          attemptId: attemptId,
          source: source,
          config: config,
        );
        backendSessionId = start?.sessionId;
        sessionId = attemptSessionId;
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
        await Future.wait<void>(<Future<void>>[
          _persistActiveSessionId(backendSessionId),
          _persistActiveRuntimeSessionId(sessionId),
        ]);
      }
      _throwIfConnectCancelled(attemptId);

      analyticsStage = 'native_start';
      _setConnectionProgress('Создаем защищенный туннель...', percent: 64);
      _traceConnectPhase(
        'preconnect_destructive_cleanup_skipped',
        attemptId: attemptId,
        source: source,
        sessionId: sessionId,
        deviceId: deviceId,
        config: config,
        extra: const <String, dynamic>{'destructive_cleanup': false},
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
        final terminalNativeTimeout = _isTerminalNativeStartTimeout(e);
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
            'terminal_native_timeout': terminalNativeTimeout,
          },
        );
        if (terminalNativeTimeout) {
          _traceConnectPhase(
            'native_start_retry_skipped',
            attemptId: attemptId,
            source: source,
            sessionId: sessionId,
            deviceId: deviceId,
            config: config,
            extra: const <String, dynamic>{'reason': 'native_start_timeout'},
          );
          rethrow;
        }
        if (!configFromCache) rethrow;
        await _removeCachedConfig(
          serverId: selectedServerId,
          protocol: _selectedProtocol.id,
          deviceId: deviceId,
        );
        config = await _fetchConfigWithRetry(
          serverId: selectedServerId,
          deviceId: deviceId,
          protocol: selectedProtocolId,
          attemptId: attemptId,
          source: source,
          reason: 'cached_config_start_exception',
        );
        await _writeCachedConfig(
          config,
          serverId: config.server?.id ?? selectedServerId,
          deviceId: deviceId,
        );
        _throwIfConnectCancelled(attemptId);
        _serverName = config.serverName;
        if (config.server != null) {
          _selectedServer = config.server;
          unawaited(_persistSelectedServerId(config.server!.id));
        }
        _setConnectionProgress(
          'Пробуем другой маршрут подключения...',
          percent: 72,
        );
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
          deviceId: deviceId,
        );
        config = await _fetchConfigWithRetry(
          serverId: selectedServerId,
          deviceId: deviceId,
          protocol: selectedProtocolId,
          attemptId: attemptId,
          source: source,
          reason: 'cached_config_start_false',
        );
        await _writeCachedConfig(
          config,
          serverId: config.server?.id ?? selectedServerId,
          deviceId: deviceId,
        );
        _throwIfConnectCancelled(attemptId);
        _serverName = config.serverName;
        if (config.server != null) {
          _selectedServer = config.server;
          unawaited(_persistSelectedServerId(config.server!.id));
        }
        _setConnectionProgress(
          'Пробуем оптимизировать маршрут...',
          percent: 72,
        );
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

      // Android native start methods return true only after the shared runtime
      // has verified protected traffic. Treat that result as a redundant proof
      // channel so a missed/racing EventChannel edge cannot time out and tear
      // down a healthy tunnel.
      if (_nativeStartResultVerifiesDataPlane) {
        _markDataPlaneReady(
          attemptSessionId,
          source: 'native_start_verified_result',
        );
      }

      _rememberConnectedConfig(
        config: config,
        deviceId: deviceId,
        configFromCache: configFromCache,
      );
      _setConnectionProgress('Проверяем защищенный трафик...', percent: 92);
      analyticsStage = 'connectivity_gate';
      _throwIfConnectCancelled(attemptId);
      try {
        await _waitForVerifiedDataPlane(attemptSessionId);
      } on TimeoutException {
        await _runtime
            .disconnect(
              reason: 'dataplane_verification_timeout',
              source: '${source}_dataplane_gate',
              sessionId: attemptSessionId,
              includeLegacy: true,
            )
            .catchError((_) => false);
        rethrow;
      }
      _throwIfConnectCancelled(attemptId);
      final windowsConnectivityOk = await _verifyWindowsTunnelConnectivity(
        protocol: config.protocol,
        sessionId: backendSessionId ?? sessionId,
        deviceId: deviceId,
      );
      _throwIfConnectCancelled(attemptId);
      if (!windowsConnectivityOk) {
        final failedDiagnostics = await _desktopVpnDiagnosticsForLogs();
        _traceConnectPhase(
          'windows_connectivity_gate_failed',
          attemptId: attemptId,
          source: source,
          sessionId: sessionId,
          deviceId: deviceId,
          config: config,
          extra: <String, dynamic>{
            if (failedDiagnostics.isNotEmpty)
              'desktop_vpn_diagnostics': failedDiagnostics,
          },
        );
        await _runtime
            .disconnect(
              reason: 'connectivity_gate_failed',
              source: '${source}_connectivity_gate',
              sessionId: sessionId,
            )
            .catchError((_) => false);
        throw VpnException(
          'Туннель запущен, но защищённый интернет недоступен. '
          'Проверьте сеть или выберите другой протокол.',
        );
      }
      final desktopDiagnostics = await _desktopVpnDiagnosticsForLogs();
      unawaited(
        _api.log(
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
        ),
      );
      unawaited(
        _logRuntimeDiagnosticDump(
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
        ),
      );
      _throwIfConnectCancelled(attemptId);
      _flushPendingNativeTrafficProof();
      _connectedAt = DateTime.now().toUtc();
      _firstProofAt = null;
      _lastRxBytes = 0;
      _lastTxBytes = 0;
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
      _clearDataPlaneGate();
      analyticsStage = 'completed';
      logConnectResult(result: 'native_connected');
      _startEntitlementTimer();
      if (backendSessionDeferred) {
        unawaited(
          _startBackendSessionAfterCachedFastPath(
            config: config,
            deviceId: deviceId,
            runtimeSessionId: sessionId,
            attemptId: attemptId,
            source: source,
          ),
        );
      } else {
        _scheduleNodeTrafficVerification();
      }
    } on SimpleVpnAccessRequiredException catch (e) {
      logConnectResult(
        result: 'access_required',
        errorFamily: 'access_required',
      );
      if (!_isCurrentConnectOwner(attemptId: attemptId, sessionId: sessionId)) {
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
      logConnectResult(result: 'device_limit', errorFamily: 'device_limit');
      if (!_isCurrentConnectOwner(attemptId: attemptId, sessionId: sessionId)) {
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
      _pendingNativeTrafficProof = null;
      _clearDataPlaneGate();
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
      logConnectResult(
        result: cancelled ? 'cancelled' : 'failed',
        errorFamily: _connectFailureFamily(e),
      );
      if (!_isCurrentConnectOwner(attemptId: attemptId, sessionId: sessionId)) {
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
        await _terminateBackendSession(
          sessionId: backendSessionToStop,
          reason: cancelled ? 'user_cancel' : 'connect_failed',
          deviceId: deviceId,
        );
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
        _pendingNativeTrafficProof = null;
        _clearDataPlaneGate();
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
      unawaited(
        _logRuntimeDiagnosticDump(
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
        ),
      );
      _sessionId = null;
      await _clearActiveSessionId();
      _lastConnectedConfig = null;
      _lastConnectedDeviceId = null;
      _runtimeSessionId = null;
      _nodeTrafficVerifiedForSession = false;
      _pendingNativeTrafficProof = null;
      _clearDataPlaneGate();
      _setState(SimpleVpnState.error);
    } finally {
      if (!analyticsResultLogged) {
        logConnectResult(result: 'superseded', errorFamily: 'superseded');
      }
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
    final cachedSid = _sessionId;
    final cachedRuntimeSid = _runtimeSessionId ?? cachedSid;
    final cachedDeviceId = _lastConnectedDeviceId;
    final sidFuture = cachedSid == null
        ? _readActiveSessionId()
        : Future<String?>.value(cachedSid);
    final runtimeSidFuture = cachedRuntimeSid == null
        ? _readActiveRuntimeSessionId()
        : Future<String?>.value(cachedRuntimeSid);
    final deviceIdFuture = cachedDeviceId == null
        ? _resolveDeviceId()
        : Future<String?>.value(cachedDeviceId);

    // Start the only user-visible critical operation immediately. Persistent
    // session/device reads are needed only for backend bookkeeping and run in
    // parallel with native teardown.
    final nativeDisconnectFuture = _runtime.disconnect(
      reason: reason,
      source: source,
      sessionId: cachedRuntimeSid,
      includeLegacy: true,
    );
    final sid = await sidFuture;
    final backendSid = _backendSessionId(sid);
    final runtimeSid = cachedRuntimeSid ?? await runtimeSidFuture ?? sid;
    final deviceId = cachedDeviceId ?? await deviceIdFuture;
    final connectedAt = _connectedAt;
    final firstProofAt = _firstProofAt;
    final connectedConfig = _lastConnectedConfig;
    final endedAt = DateTime.now().toUtc();
    final connectionDurationMs = connectedAt == null
        ? null
        : endedAt.difference(connectedAt).inMilliseconds.clamp(0, 1 << 31);
    final proofLatencyMs = connectedAt == null || firstProofAt == null
        ? null
        : firstProofAt.difference(connectedAt).inMilliseconds.clamp(0, 1 << 31);
    // Cache deletion is independent from native teardown. Start it now so the
    // (occasionally slow) SharedPreferences fsync is hidden behind the VPN
    // shutdown instead of extending the visible disconnect state afterwards.
    final clearActiveSessionFuture = _clearActiveSessionId();
    var nativeStopped = false;
    try {
      // Android's native coordinator only returns true after its own runtime
      // and the system VPN are down (or after the bounded stale-system grace).
      // Do not poll the same slow platform channels a second time: on loaded
      // devices that redundant check kept the UI in "disconnecting" for
      // another 2-4 seconds and made the next tap look ignored.
      nativeStopped = await nativeDisconnectFuture;
      final runtimeDown = nativeStopped ||
          await _waitForRuntimeDown(timeout: _disconnectBarrierTimeout);

      _sessionId = null;
      await clearActiveSessionFuture;
      _lastConnectedConfig = null;
      _lastConnectedDeviceId = null;
      _runtimeSessionId = null;
      _nodeTrafficVerifiedForSession = false;
      _pendingNativeTrafficProof = null;
      _clearDataPlaneGate();
      _stopEntitlementTimer();
      _clearConnectionProgress();
      _setState(SimpleVpnState.disconnected);

      await _terminateBackendSession(
        sessionId: backendSid,
        reason: reason,
        deviceId: deviceId,
      );
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
          'protocol': connectedConfig?.protocol ?? _selectedProtocol.id,
          'server_id': connectedConfig?.server?.id ?? _selectedServer?.id,
          'connection_duration_ms': connectionDurationMs,
          'proof_latency_ms': proofLatencyMs,
          'rx_bytes': _lastRxBytes,
          'tx_bytes': _lastTxBytes,
          'service_proof_seen': firstProofAt != null,
          'terminal_source': 'simple_vpn_controller',
        },
      ).catchError((_) {});
      _connectedAt = null;
      _firstProofAt = null;
      _activeConnectStartedAt = null;
      _reportedConnectionPhases.clear();
      _lastRxBytes = 0;
      _lastTxBytes = 0;
      unawaited(
        _logRuntimeDiagnosticDump(
          phase: 'after_disconnect_ok',
          source: source,
          deviceId: deviceId,
          sessionId: sid,
          level: 'info',
          includeNetworkProbe: true,
          extra: <String, dynamic>{'reason': reason},
        ),
      );
    } catch (e) {
      final nativeDown =
          nativeStopped || (await _runtime.getAmneziaWgStatus()) == false;
      _sessionId = null;
      await clearActiveSessionFuture;
      _lastConnectedConfig = null;
      _lastConnectedDeviceId = null;
      _runtimeSessionId = null;
      _nodeTrafficVerifiedForSession = false;
      _pendingNativeTrafficProof = null;
      _clearDataPlaneGate();
      _connectedAt = null;
      _firstProofAt = null;
      _activeConnectStartedAt = null;
      _reportedConnectionPhases.clear();
      _lastRxBytes = 0;
      _lastTxBytes = 0;
      _stopEntitlementTimer();
      _clearConnectionProgress();
      if (nativeDown) {
        await _terminateBackendSession(
          sessionId: backendSid,
          reason: reason,
          deviceId: deviceId,
        );
        unawaited(
          _api.log(
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
          ),
        );
        unawaited(
          _logRuntimeDiagnosticDump(
            phase: 'disconnect_native_down_tail_failed',
            source: source,
            deviceId: deviceId,
            sessionId: sid,
            level: 'warning',
            includeNetworkProbe: true,
            extra: <String, dynamic>{'error': e.toString(), 'reason': reason},
          ),
        );
        _setState(SimpleVpnState.disconnected);
        return;
      }

      _error = e.toString();
      await _terminateBackendSession(
        sessionId: backendSid,
        reason: reason,
        deviceId: deviceId,
      );
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
      unawaited(
        _logRuntimeDiagnosticDump(
          phase: 'disconnect_failed',
          source: source,
          deviceId: deviceId,
          sessionId: sid,
          level: 'error',
          includeNetworkProbe: true,
          extra: <String, dynamic>{'error': _error, 'reason': reason},
        ),
      );
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
    unawaited(
      _logUiStateTransition(
        traceId: traceId,
        previous: previous,
        next: next,
        sessionId: sessionId,
        deviceId: deviceId,
        base: payload,
      ),
    );
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
        nativeConnected = await _runtime.getNativeConnectionStatus().timeout(
              const Duration(milliseconds: 800),
            );
      } catch (e) {
        nativeError = e.toString();
      }
      try {
        awgConnected = await _runtime.getAmneziaWgStatus().timeout(
              const Duration(milliseconds: 800),
            );
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

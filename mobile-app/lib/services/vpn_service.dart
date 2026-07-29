import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:dio/dio.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../models/server.dart';
import '../models/vpn_protocol.dart';
import '../config/app_config.dart';
import 'native_vpn_service.dart';
import 'auth_service.dart';
import 'connection_logger.dart';
import '../core/api/api_client.dart'; // ApiClient, ApiClientInterface
import '../core/api/network_timeouts.dart';
import '../core/api/preferred_route_storage.dart';
import '../core/logger/logger.dart';
import '../core/cache/cache_service.dart';
import '../core/storage/storage_service.dart';
import '../core/errors/error_handler.dart';
import '../core/perf/perf_logger.dart';
import '../core/vpn/vpn_connection_models.dart';
import '../core/vpn_state_machine.dart';
import '../core/vpn/vpn_orchestration_runtime.dart';
import '../core/vpn/control_plane_client.dart';
import '../core/vpn/vpn_log_redaction.dart';
import '../core/vpn/vpn_operation_guards.dart';
import '../core/vpn/vpn_orchestration_spec.dart'
    show ControlPlanePlane, TunnelVerifyCriteria, VpnOrchestrationSpec;
import '../core/network/server_latency_probe.dart';
import '../core/vpn_protocol_handler/vpn_protocol_handler.dart';
import '../protocols/xray/xray_protocol.dart';
import 'xray_connection_handler.dart';
import '../simple_vpn/simple_vpn_options_cache.dart';
// WireGuard протокол работает через базовый VPN интерфейс без полной криптографии
// Для полной поддержки WireGuard требуется интеграция wireguard-android библиотеки
// import '../protocols/wireguard/wireguard_protocol.dart';
part '../core/vpn/connect_attempt_executor.dart';
part '../core/vpn/disconnect_pipeline_executor.dart';
part '../core/vpn/disconnect_state_helpers.dart';
part '../core/vpn/connect_state_helpers.dart';
part '../core/vpn/connect_disconnect_facade.dart';
part '../core/vpn/device_registration_helpers.dart';
part '../core/vpn/server_protocol_cache_helpers.dart';
part '../core/vpn/network_mtu_helpers.dart';
part '../core/vpn/native_runtime_state_helpers.dart';
part '../core/vpn/post_connect_commit_helpers.dart';
part '../core/vpn/runtime_contract_helpers.dart';
part '../core/vpn/device_identity_helpers.dart';
part '../core/vpn/connect_pipeline_helpers.dart';
part '../core/vpn/server_catalog_helpers.dart';
part '../core/vpn/traffic_monitoring_helpers.dart';
part '../core/vpn/protocol_adapter_helpers.dart';
part '../core/vpn/sync_control_helpers.dart';
part '../core/vpn/server_selection_auth_helpers.dart';
part '../core/vpn/session_lifecycle_helpers.dart';

/// Xray protocols are archived after the 2026-05-13 AmneziaWG baseline.
/// Keep the list only for explicit R&D builds, never for MVP default.
const _xrayProtocolPriority = [
  'xray_vless',
  'xray_vless_ws_tls',
  'xray_vless_grpc_tls',
  'xray_reality',
  'xray_vmess',
];

/// Ключи для сохранения последнего выбора сервера и протокола (при отключении VPN показываем их на экране подписки).
const _keyLastConnectedServerId = 'last_connected_server_id';
const _keyLastConnectedProtocol = 'last_connected_protocol';

/// Emergency product switch: after auth expose one working VPN button.
/// Observability/logging stays passive, but server/protocol selection is fixed.
const bool _minimalVpnMode = false;
const String _minimalVpnServerId = '1'; // HU-BUD-01
const VpnProtocol _minimalVpnProtocol = VpnProtocol.graniwg;

enum VpnUiControlSource { app, quickTileOrSystem, unknown }

enum VpnUiConnectIntent { none, connect, reconnect, disconnect }

abstract class VpnDisconnectReason {
  static const String user = 'user_disconnect';
  static const String verifyFailed = 'verify_failed';
  static const String networkChangeReconnect = 'network_change_reconnect';
  static const String authLost = 'auth_lost';
  static const String protocolSwitch = 'protocol_switch';
  static const String serverSwitch = 'server_switch';
}

class StaleConnectSessionException implements Exception {
  const StaleConnectSessionException(this.stage);
  final String stage;
  @override
  String toString() => 'StaleConnectSessionException(stage=$stage)';
}

class VpnService extends ChangeNotifier {
  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isDisconnecting = false;

  /// Single source of truth for connection state; use _applyTransition to update.
  VpnConnectionState _currentState = VpnConnectionState.idle;
  bool _isPaused = false;
  bool _resumeSyncInProgress = false;
  DateTime? _resumeSyncGuardUntil;
  DateTime? _resumeSyncWallStartedAt;
  static const Duration _resumeConnectGuardDuration = Duration(seconds: 2);
  Server? _selectedServer;
  VpnProtocol _selectedProtocol = VpnProtocol.graniwg;
  DateTime? _connectionStartTime;
  List<Server> _servers = [];
  String? _deviceId;
  String? _cachedFingerprint;
  String? _vpnConfig;
  String? _currentIpAddress;
  String? _clientId; // Для Xray протоколов
  /// Идентификатор сессии подключения (один на весь цикл connect → success/error/disconnect). Для мониторинга и поиска пробелов.
  String? _connectionSessionId;
  String? _cachedEffectiveOutbounds;
  Map<String, dynamic>? _lastNativeRuntimeDiag;
  DateTime? _lastNativeRuntimeDiagAt;
  Map<String, dynamic>? _lastRuntimeContract;
  String? _lastRuntimeCorrelationId;
  String? _pendingApplyConfigRevision;
  String? _pendingApplyPhase;
  bool _applyAckBackgroundInFlight = false;
  bool _connectedWithAckDelay = false;
  final Set<String> _cancelledConnectionSessions = <String>{};

  /// Причина подключения: first_connect | reconnect_after_network_change. При использовании кэша добавляется stage reconnect_from_cache.
  String? _connectionTrigger;
  String? _lastError;

  /// Last user-facing connection error message (set when connect() returns false after a failure).
  String? _lastConnectionErrorMessage;
  String? get lastConnectionErrorMessage => _lastConnectionErrorMessage;
  @visibleForTesting
  bool get connectedWithAckDelayForTest => _connectedWithAckDelay;
  @visibleForTesting
  String? get lastConnectFailReasonForTest => _lastConnectFailReason;
  String? _lastConnectFailCode;
  String? _lastConnectFailStage;
  String? _lastConnectFailReason;
  XrayProtocol? _xrayProtocol; // Для Xray протоколов
  bool _xrayAvailable = false;
  bool _killSwitchEnabled = false; // Kill Switch
  List<String> _splitTunnelingApps = []; // Split Tunneling
  // Статистика трафика
  int _totalBytesReceived = 0;
  int _totalBytesSent = 0;
  StreamSubscription<Map<dynamic, dynamic>>? _nativeVpnStateSubscription;
  Timer? _trafficStatsTimer;

  /// Редкая сверка Dart↔native при длительном VPN (пропущенные события EventChannel).
  Timer? _nativeConnectedSafetyTimer;
  static const Duration _nativeConnectedSafetyInterval = Duration(seconds: 60);

  /// Снимок [NativeVpnService.channelCallSnapshot] на старте мониторинга трафика (дельта в лог при остановке).
  Map<String, int>? _trafficMonitorChannelStatsStart;
  int _prevTotalBytesForSpeed = 0;
  DateTime? _prevTrafficStatsTime;
  double? _currentSpeedMbps;

  /// Был ли хотя бы раз зафиксирован трафик через VPN (для понятного UI «трафик идёт» / «ожидание»)
  bool _hasEverSeenTraffic = false;

  // Автоматическое переподключение (ОТКЛЮЧЕНО для тестирования)
  bool _autoReconnectEnabled = false; // Отключено для тестирования
  int _reconnectionAttempts = 0;
  static const int _maxReconnectionAttempts = 5;
  static const Duration _reconnectionDelay = Duration(seconds: 5);

  // MTU подбор для мобильных сетей
  static const int _mtuWifi = 1500;
  static const int _mtuMobile = 1280;
  static const int _mtuDefault = 1420;
  static const List<int> _mobileMtuFallbackProfile = <int>[1280, 1240, 1200];
  static const List<int> _wifiMtuFallbackProfile = <int>[1500, 1420, 1360];
  int? _pendingMtuOverride;
  String? _pendingMtuReason;
  String? _lastNetworkType;
  int? _lastMtu;

  // Прогресс подключения
  ConnectionProgress? _connectionProgress;
  ConnectionProgress? get connectionProgress => _connectionProgress;
  ConnectionFlowType _connectionFlowType = ConnectionFlowType.unknown;
  ConnectionFlowType get connectionFlowType => _connectionFlowType;
  DateTime? _connectionAttemptStartedAt;
  DateTime? get connectionAttemptStartedAt => _connectionAttemptStartedAt;

  // Debounce для refreshServers
  bool _isRefreshing = false;
  DateTime? _lastRefreshTime;
  // Кардинально режем шум /vpn/servers: без force повторяем не чаще раза в минуту.
  static const Duration _refreshDebounceInterval = Duration(seconds: 60);

  // Sync состояния с сервером только при первом connect в сессии (оптимизация 5s)
  bool _connectionStateSyncDoneThisSession = false;

  bool _deviceRegistrationDoneThisSession = false;
  bool _authAccessTokenRefreshHookRegistered = false;
  DateTime? _lastEnsureDeviceRegisteredAt;
  static const Duration _ensureDeviceRegisteredCooldown = Duration(minutes: 3);
  static const Duration _deviceRegistrationFallbackTtl = Duration(hours: 24);
  static const Duration _deviceRegistrationMaxTtl = Duration(days: 30);

  /// Параллельные вызовы [ensureDeviceRegistered] (фон после логина + connect) — один in-flight [Future].
  Future<void>? _ensureDeviceRegisterInFlight;
  List<dynamic>? _lastDevicesSnapshot;
  DateTime? _lastDevicesSnapshotAt;
  static const Duration _devicesSnapshotTtl = Duration(minutes: 2);
  static const Duration _devicesFetchCooldown = Duration(seconds: 4);
  Future<List<dynamic>>? _fetchDevicesInFlight;

  /// Throttle / backoff для GET /vpn/status (меньше запросов при ошибках и таймаутах).
  DateTime? _nextVpnStatusSyncAllowedAt;
  int _vpnStatusSyncConsecutiveFailures = 0;
  static const Duration _vpnStatusSyncBaseInterval = Duration(seconds: 8);
  static const Duration _vpnStatusSyncMaxBackoff = Duration(seconds: 120);
  bool _vpnStatusSyncInFlight = false;

  /// Wall-clock старта текущего полёта [_syncConnectionState] (GET /vpn/status + опц. disconnect).
  /// Путь connect() свободен от блокировки «проверка состояния» когда флаг сброшен в `finally`
  /// (обычно сразу после ответа API; верхняя граница — [NetworkTimeouts.vpnStatusWallTimeout] + до 6 с на disconnect).
  DateTime? _vpnStatusSyncFlightStartedAt;
  Future<void>? _sessionPreparePrewarmInFlight;
  DateTime? _lastSessionPreparePrewarmAt;
  String? _lastSessionPreparePrewarmKey;
  static const Duration _sessionPreparePrewarmCooldown = Duration(minutes: 2);

  /// Последние метрики времени подключения по этапам (для логов и аналитики)
  final Map<String, int> _lastConnectionTimingMs = {};
  Map<String, int> get lastConnectionTimingMs =>
      Map.unmodifiable(_lastConnectionTimingMs);

  /// Сколько миллисекунд уже идёт текущий запрос /vpn/status (null, если не in flight).
  int? get vpnStatusSyncInFlightAgeMs {
    final t = _vpnStatusSyncFlightStartedAt;
    if (!_vpnStatusSyncInFlight || t == null) return null;
    return DateTime.now().difference(t).inMilliseconds;
  }

  /// Автопереподключение при смене сети (Wi‑Fi ↔ мобильный): отключаемся и подключаемся заново с правильным MTU.
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Timer? _networkChangeDebounce;
  bool _reconnectAfterNetworkChange = false;

  /// Время старта последнего connect(), вызванного после смены сети — для cooldown перед следующей сменой.
  DateTime? _lastReconnectConnectStartedAt;

  /// Флаг: текущий вызов connect() запущен отложенным коллбэком после смены сети (для логирования).
  bool _connectTriggeredByNetworkChange = false;

  /// После resume из фона игнорируем смену сети до этого момента (чтобы не рвать соединение сразу).
  DateTime? _ignoreNetworkChangeUntil;

  /// Последовательная очередь [syncConnectionStateWithNative] (избегает гонок getStatus при resume).
  Future<void> _nativeUiSyncChain = Future<void>.value();

  /// Защита от одновременного выполнения connect и disconnect.
  bool _connectInProgress = false;
  bool _disconnectInProgress = false;

  /// Параллельные вызовы connect() ждут один и тот же Future (двойной тап / race до _applyTransition(connecting)).
  Future<bool>? _connectFutureGate;

  /// Время завершения последнего connect-пайплайна (success/fail/cancel).
  DateTime? _lastConnectFinishedAt;
  DateTime? _lastManualConnectTapAt;

  /// Минимальная пауза между полными connect-пайплайнами, чтобы не запускать шторм попыток.
  static const Duration _minDelayBetweenConnectAttempts =
      Duration(milliseconds: 1200);
  static const Duration _diagnosticSingleTapCooldown = Duration(seconds: 20);

  /// Диагностический режим: разрешаем только ручной connect, автотриггеры reconnect блокируем.
  static const bool _diagnosticManualConnectOnly = true;

  /// Время завершения последнего disconnect — для паузы перед быстрым повторным connect (tun2socks race).
  DateTime? _lastDisconnectCompletedAt;

  /// 500 ms — tun2socks в отдельном процессе, native delay 200 ms, суммарно достаточно для стабильного reconnect.
  static const Duration _minDelayAfterDisconnect = Duration(milliseconds: 500);

  /// Closing runtime-path fix:
  /// отключаем warm-cache reconnect для Xray, чтобы каждый connect проходил через
  /// свежий control-plane fetch/apply и не зависел от локального stale runtime-кэша.
  static const bool _diagnosticAllowReconnectFromCache = false;

  /// Пропуск addPostFrameCallback в disconnect — для тестов без прокачки кадров.
  static bool debugBypassFrameDelay = false;

  /// Пропуск _syncConnectionState при connect (упрощение цепочки).
  static const bool _skipSyncConnectionStateOnConnect = false;

  /// Флаг: последний connect использовал конфиг из кэша (для расширенной диагностики в _verifyConnection).
  bool _diagnosticReconnectFromCache = false;

  /// Время старта connect() для диагностики таймингов.
  DateTime? _diagnosticConnectStartAt;

  /// Время, когда туннель подтвердил connected на текущей сессии.
  DateTime? _lastTunnelConnectedAt;

  /// Строгий post-connect commit: не считаем VPN "реально рабочим", пока нет подтверждения probe+traffic.
  Timer? _postConnectCommitTimer;
  static const Duration _postConnectCommitWindow = Duration(seconds: 10);
  static const Duration _postConnectProbeFreshness = Duration(seconds: 25);
  static const Duration _postConnectMinRetryWindow = Duration.zero;
  static const int _postConnectMinFailedProbeCount = 1;
  bool _postConnectCommitLogged = false;
  bool _postConnectConnectivityDegraded = false;
  String? _postConnectDegradedReason;
  bool? _postConnectPublicOk;
  bool? _postConnectApiOk;
  DateTime? _lastConnectivityProbeAt;
  DateTime? _postConnectFirstFailedProbeAt;
  int _postConnectFailedProbeCount = 0;
  int _datapathCheckpointSeq = 0;

  /// Защита от мгновенного самосброса сразу после xray_connected.
  static const Duration _userDisconnectDebounceAfterConnect =
      Duration(seconds: 8);

  /// Флаг текущей сессии connect: нужно ли запускать таймер триала. При подписке — false.
  bool _connectStartTrialTimer = true;

  /// Источник последнего изменения transport state (app vs внешний контроллер: quick tile/system).
  VpnUiControlSource _lastControlSource = VpnUiControlSource.unknown;

  /// Намерение текущего перехода для UI: обычный connect / reconnect / disconnect.
  VpnUiConnectIntent _uiConnectIntent = VpnUiConnectIntent.none;

  // Core компоненты (полная инъекция через конструктор)
  final ApiClientInterface _apiClient;
  final Logger _logger;
  final CacheService _cacheService;
  final StorageService _storageService;
  final ErrorHandler _errorHandler;
  final ConnectionLogger _connectionLogger;
  final AuthService _authService;

  /// Опциональная фабрика обработчиков протоколов (для тестов и будущей подмены реализации).
  final VpnProtocolHandler? Function(VpnProtocol)? _handlerFactory;

  XrayConnectionHandler? _xrayHandler;
  XrayConnectionHandler get _xrayConnectionHandler {
    _xrayHandler ??= XrayConnectionHandler(
      apiClient: _apiClient,
      cache: StorageXrayConfigCache(
        _storageService,
        isXrayConfigValidForStorage,
      ),
      forceDisconnectOnServer: (token) => _forceDisconnectOnServer(token),
      log: _log,
    );
    return _xrayHandler!;
  }

  void _log(String message) => _logger.debug(message, 'VpnService');

  /// Все зависимости передаются извне (полная инъекция). [authService] — тот же экземпляр, что в Provider/GetIt.
  /// [handlerFactory] — опционально: фабрика обработчиков протоколов; если задана и возвращает handler, он используется вместо встроенной логики.
  /// [skipInitialize] — если true, не вызывается _initialize() (для тестов).
  VpnService({
    required ApiClientInterface apiClient,
    required Logger logger,
    required CacheService cacheService,
    required StorageService storageService,
    required ErrorHandler errorHandler,
    required ConnectionLogger connectionLogger,
    required AuthService authService,
    VpnProtocolHandler? Function(VpnProtocol)? handlerFactory,
    bool skipInitialize = false,
  })  : _apiClient = apiClient,
        _logger = logger,
        _cacheService = cacheService,
        _storageService = storageService,
        _errorHandler = errorHandler,
        _connectionLogger = connectionLogger,
        _authService = authService,
        _handlerFactory = handlerFactory {
    _authService.attachVpnConnectFlowGate(_isConnectFlowGateActive);
    ControlPlaneClient.instance
        .attachVpnConnectBlockingGate(_isConnectFlowGateActive);
    if (!skipInitialize) {
      _ensureAuthAccessTokenRefreshHook();
      _initialize().catchError((error) {
        _logger.error('Ошибка инициализации VPN сервиса', 'VpnService', error);
        // Продолжаем работу, серверы можно загрузить позже
      });
    }
  }

  @visibleForTesting
  static String classifyCommitFailureReasonForTest({
    required bool publicOk,
    required bool apiOk,
    required bool trafficSeen,
  }) {
    if (!trafficSeen) return 'commit_failed_no_traffic';
    if (!publicOk && apiOk) return 'commit_failed_public_only';
    if (publicOk && !apiOk) return 'commit_failed_api_only';
    if (!publicOk && !apiOk) return 'commit_failed_public_and_api';
    return 'commit_failed_unknown';
  }

  @visibleForTesting
  static Map<String, dynamic> buildCommitFailureBundleForTest({
    required String reasonClass,
    required bool trafficSeen,
    required bool publicOk,
    required bool apiOk,
    required int failedProbeCount,
    required String? connectionSessionId,
    required String? trigger,
    required String? effectiveOutbounds,
    required DateTime? probeAt,
    required DateTime? runtimeDiagAt,
    required Map<String, dynamic>? runtimeDiag,
    required DateTime now,
  }) {
    final bundle = <String, dynamic>{
      'reason_class': reasonClass,
      'traffic_seen': trafficSeen,
      'public_ok': publicOk,
      'api_ok': apiOk,
      'failed_probe_count': failedProbeCount,
      'connection_session_id': connectionSessionId,
      'trigger': trigger,
      if (effectiveOutbounds != null && effectiveOutbounds.isNotEmpty)
        'effective_outbounds': effectiveOutbounds,
    };
    if (probeAt != null) {
      bundle['probe_age_ms'] = now.difference(probeAt).inMilliseconds;
    }
    if (runtimeDiagAt != null) {
      bundle['last_native_runtime_diag_age_ms'] =
          now.difference(runtimeDiagAt).inMilliseconds;
    }
    if (runtimeDiag != null && runtimeDiag.isNotEmpty) {
      bundle['last_native_runtime_diag'] =
          Map<String, dynamic>.from(runtimeDiag);
    }
    return bundle;
  }

  @override
  void dispose() {
    _nativeVpnStateSubscription?.cancel();
    _nativeVpnStateSubscription = null;
    _trafficStatsTimer?.cancel();
    _trafficStatsTimer = null;
    _nativeConnectedSafetyTimer?.cancel();
    _nativeConnectedSafetyTimer = null;
    super.dispose();
  }

  void _notifyListenersFromHelper() {
    notifyListeners();
  }

  Future<bool> _runDisconnectPipeline({
    required String reason,
    required String source,
  }) async {
    return _DisconnectPipelineExecutor(this).run(
      reason: reason,
      source: source,
    );
  }

  Future<void> refreshControlPlaneSnapshot(
    AuthService authService, {
    bool force = false,
  }) async {
    if (_isRefreshing) return;
    if (!force && _lastRefreshTime != null) {
      final delta = DateTime.now().difference(_lastRefreshTime!);
      if (delta < _refreshDebounceInterval) return;
    }

    _isRefreshing = true;
    _lastRefreshTime = DateTime.now();
    try {
      final token = await _getAuthToken();
      if (token == null || token.isEmpty) return;

      final response = await _apiClient.get(
        '/vpn/control-plane-snapshot',
        options: await _vpnApiOptions(
          {'Authorization': 'Bearer $token'},
          readHeavy: true,
        ),
      );
      if (response.statusCode != 200 || response.data is! Map) return;

      final map = Map<String, dynamic>.from(response.data as Map);
      final userRaw = map['user'];
      if (userRaw is Map) {
        await authService.applyUserStatusSnapshot(
          Map<String, dynamic>.from(userRaw),
          notify: false,
        );
      }

      final serversRaw = map['servers'];
      if (serversRaw is List) {
        final parsed = <Server>[];
        for (final item in serversRaw) {
          if (item is! Map) continue;
          try {
            parsed.add(Server.fromJson(Map<String, dynamic>.from(item)));
          } catch (_) {}
        }

        final filtered = parsed.where((server) {
          if (!server.isActive) return false;
          final protocols = server.supportedProtocols ?? const <String>[];
          if (protocols.isEmpty) return true;
          return protocols.contains('wireguard') ||
              protocols.any((p) => p.startsWith('xray_'));
        }).toList();
        _servers = filtered.isNotEmpty ? filtered : parsed;

        if (_selectedServer != null && _servers.isNotEmpty) {
          _selectedServer = _servers.firstWhere(
            (s) => s.id == _selectedServer!.id,
            orElse: () => _servers.first,
          );
        } else if (_selectedServer == null && _servers.isNotEmpty) {
          await _restoreLastConnectedSelection();
          _selectedServer ??= _servers.first;
        }
        await _saveServersToCache(_servers);
        await _saveSimpleVpnOptionsCacheFromSnapshot(serversRaw);
      }

      authService.notifyListeners();
      notifyListeners();
    } catch (e) {
      _log('VpnService.refreshControlPlaneSnapshot: $e');
    } finally {
      _isRefreshing = false;
    }
  }

  Future<void> _saveSimpleVpnOptionsCacheFromSnapshot(
      Object? serversRaw) async {
    final simpleServers = simpleVpnServersFromSnapshot(serversRaw);
    if (simpleServers.isEmpty) return;
    try {
      await _cacheService.setString(
        simpleVpnOptionsCacheKey,
        jsonEncode(
          buildSimpleVpnOptionsCachePayload(servers: simpleServers),
        ),
        ttl: simpleVpnOptionsCacheTtl,
      );
      _log(
        'VpnService.simpleVpnOptionsCacheSavedFromSnapshot '
        'servers=${simpleServers.length}',
      );
    } catch (e) {
      _log('VpnService.simpleVpnOptionsCacheSaveFailed: $e');
    }
  }
}

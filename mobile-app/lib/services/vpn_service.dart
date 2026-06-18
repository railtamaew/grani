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
// WireGuard протокол работает через базовый VPN интерфейс без полной криптографии
// Для полной поддержки WireGuard требуется интеграция wireguard-android библиотеки
// import '../protocols/wireguard/wireguard_protocol.dart';
part '../core/vpn/connect_attempt_executor.dart';
part '../core/vpn/disconnect_pipeline_executor.dart';
part '../core/vpn/disconnect_state_helpers.dart';
part '../core/vpn/connect_state_helpers.dart';
part '../core/vpn/connect_disconnect_facade.dart';

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

  /// Устройство уже зарегистрировано в этой сессии — при повторном подключении не вызываем /vpn/device/register. Сбрасывается в resetSession() (например при logout).
  bool _deviceRegistrationDoneThisSession = false;
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

  void _logConnectSessionStage(
    String stage, {
    String? result,
    Map<String, Object?> extra = const <String, Object?>{},
  }) {
    final sid = _connectionSessionId ?? '-';
    final details = <String, Object?>{
      'stage': stage,
      if (result != null) 'result': result,
      'session': sid,
      'state': _currentState.name,
      ...extra,
    };
    final payload = details.entries.map((e) => '${e.key}=${e.value}').join(' ');
    // В release Logger.debug не печатает в logcat, поэтому для диагностики
    // критичного connect pipeline дублируем в debugPrint.
    _log('connect_stage $payload');
    debugPrint('[connect_stage] $payload');
  }

  /// Тайминги Xray-подключения (grep: [xray-timing]).
  /// Формат близок к auth-timing: одно событие в одну строку.
  void _logXrayTiming(String event, Map<String, dynamic> data) {
    final parts = data.entries.map((e) => '${e.key}=${e.value}').join(', ');
    debugPrint('[xray-timing] $event $parts');
  }

  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;

  /// См. [AuthService.attachVpnConnectFlowGate] — не дергать /auth/me параллельно connect.
  bool get isConnectFlowActive => _connectInProgress;
  bool get isDisconnecting => _isDisconnecting;
  bool get isPaused => _isPaused;

  /// Единое состояние VPN (state machine; обновляется через _applyTransition).
  VpnConnectionState get vpnConnectionState => _currentState;

  /// Состояние UI: отличает warm/active и reconnect.
  VpnUiSessionState get vpnUiSessionState {
    switch (_currentState) {
      case VpnConnectionState.idle:
      case VpnConnectionState.disconnected:
        return VpnUiSessionState.off;
      case VpnConnectionState.connecting:
      case VpnConnectionState.tunnelReady:
      case VpnConnectionState.tunnelVerifying:
        return _uiConnectIntent == VpnUiConnectIntent.reconnect
            ? VpnUiSessionState.reconnecting
            : VpnUiSessionState.connecting;
      case VpnConnectionState.connected:
        return _hasEverSeenTraffic
            ? VpnUiSessionState.connectedActive
            : VpnUiSessionState.connectedWarm;
      case VpnConnectionState.disconnecting:
        return VpnUiSessionState.disconnecting;
      case VpnConnectionState.error:
        return VpnUiSessionState.error;
    }
  }

  /// Последний источник изменения transport-state (полезно для UI/диагностики Quick Tile).
  VpnUiControlSource get lastUiControlSource => _lastControlSource;

  /// VPN не в состоянии «выключен»: перед logout / сбросом сессии стоит вызвать [disconnect].
  bool get isVpnSessionPotentiallyActive =>
      vpnUiSessionState != VpnUiSessionState.off;

  bool get isResumeSyncGuardActive {
    final guardUntil = _resumeSyncGuardUntil;
    return _resumeSyncInProgress ||
        (guardUntil != null && DateTime.now().isBefore(guardUntil));
  }

  void beginResumeSyncGuard() {
    _resumeSyncInProgress = true;
    _resumeSyncWallStartedAt = DateTime.now();
    _resumeSyncGuardUntil = DateTime.now().add(_resumeConnectGuardDuration);
    _log(
      'resume_sync_start guard_ms=${_resumeConnectGuardDuration.inMilliseconds}',
    );
  }

  void endResumeSyncGuard() {
    final started = _resumeSyncWallStartedAt;
    final wallMs = started != null
        ? DateTime.now().difference(started).inMilliseconds
        : -1;
    _resumeSyncInProgress = false;
    _resumeSyncGuardUntil = null;
    _resumeSyncWallStartedAt = null;
    _log(
      'resume_sync_end wall_ms=$wallMs vpn_status_sync_in_flight=$_vpnStatusSyncInFlight '
      '(если true — connect всё ещё может блокироваться до завершения /vpn/status)',
    );
  }

  bool _isConnectionSessionActive(String? sessionId) {
    if (sessionId == null || sessionId.isEmpty) return false;
    if (_connectionSessionId != sessionId) return false;
    if (_cancelledConnectionSessions.contains(sessionId)) return false;
    return _connectInProgress;
  }

  void _cancelSessionPrepareFlights({
    required String reason,
    bool markCurrentSessionCancelled = false,
  }) {
    final sid = _connectionSessionId;
    if (markCurrentSessionCancelled && sid != null && sid.isNotEmpty) {
      _cancelledConnectionSessions.add(sid);
    }
    _xrayConnectionHandler.cancelInflightSessionPrepare(
      reason: '$reason sid=${sid ?? "null"}',
    );
  }

  /// Прогрев /vpn/session/prepare до connect (cold-miss create_client уходит в фон).
  /// Без гонок: single-flight на клиенте + dedupe в XrayConnectionHandler + lock на backend.
  Future<void> prewarmSessionPrepare(
      {bool force = false, String source = 'unspecified'}) async {
    if (_minimalVpnMode) {
      _log(
          'VpnService.prewarmSessionPrepare: disabled in minimal VPN mode, source=$source');
      return;
    }
    if (_connectInProgress ||
        _disconnectInProgress ||
        _isConnectFlowGateActive()) {
      _log(
          'VpnService.prewarmSessionPrepare: skip (connect/disconnect in progress), source=$source');
      return;
    }
    if (!_isXrayProtocol) {
      _log(
          'VpnService.prewarmSessionPrepare: skip (non-xray protocol), source=$source');
      return;
    }
    if (_selectedServer == null) {
      _log(
          'VpnService.prewarmSessionPrepare: skip (selectedServer=null), source=$source');
      return;
    }
    if (_deviceId == null || _deviceId!.isEmpty) {
      await _loadDeviceId();
    }
    final token = _authService.token;
    final currentDeviceId = _deviceId;
    if (token == null ||
        token.isEmpty ||
        currentDeviceId == null ||
        currentDeviceId.isEmpty) {
      _log(
          'VpnService.prewarmSessionPrepare: skip (no token/device), source=$source');
      return;
    }

    final warmKey =
        '${_selectedServer!.id}:${_selectedProtocol.apiValue}:$currentDeviceId';
    final now = DateTime.now();
    if (!force &&
        _lastSessionPreparePrewarmKey == warmKey &&
        _lastSessionPreparePrewarmAt != null &&
        now.difference(_lastSessionPreparePrewarmAt!) <
            _sessionPreparePrewarmCooldown) {
      _log(
          'VpnService.prewarmSessionPrepare: cooldown hit key=$warmKey source=$source');
      return;
    }

    final inFlight = _sessionPreparePrewarmInFlight;
    if (inFlight != null) {
      _log(
          'VpnService.prewarmSessionPrepare: join in-flight source=$source key=$warmKey');
      return inFlight;
    }

    Future<void> run() async {
      final sw = Stopwatch()..start();
      _log(
        'VpnService.prewarmSessionPrepare: start source=$source '
        'server_id=${_selectedServer!.id} protocol=${_selectedProtocol.apiValue}',
      );
      try {
        await _xrayConnectionHandler
            .fetchConfig(
              token: token,
              server: _selectedServer!,
              protocol: _selectedProtocol,
              deviceId: currentDeviceId,
              connectionSessionId: 'prewarm:$source',
              useSessionPrepare: true,
            )
            .timeout(const Duration(seconds: 12));
        _lastSessionPreparePrewarmKey = warmKey;
        _lastSessionPreparePrewarmAt = DateTime.now();
        _log(
          'VpnService.prewarmSessionPrepare: ok source=$source '
          'elapsed_ms=${sw.elapsedMilliseconds} key=$warmKey',
        );
      } catch (e) {
        final err = e.toString().toLowerCase();
        if (err.contains('session_prepare_prewarm_skip_already_connected')) {
          _log(
            'VpnService.prewarmSessionPrepare: skip source=$source '
            'elapsed_ms=${sw.elapsedMilliseconds} reason=already_connected',
          );
          return;
        }
        _log(
          'VpnService.prewarmSessionPrepare: failed source=$source '
          'elapsed_ms=${sw.elapsedMilliseconds} error=$e',
        );
      } finally {
        sw.stop();
      }
    }

    final future = run();
    _sessionPreparePrewarmInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_sessionPreparePrewarmInFlight, future)) {
        _sessionPreparePrewarmInFlight = null;
      }
    }
  }

  /// Applies a state transition and updates flags. Use this for all connection state changes.
  void _applyTransition(VpnConnectionState newState) {
    if (!VpnStateTransitions.canTransition(_currentState, newState)) {
      _log('VpnService: invalid transition $_currentState -> $newState');
    }
    _currentState = newState;
    VpnOrchestrationRuntime.instance.setVpnState(newState);
    final flags = VpnStateTransitions.toFlags(newState);
    _isConnecting = flags.$1;
    _isDisconnecting = flags.$2;
    _isConnected = flags.$3;
    if (newState != VpnConnectionState.error) _lastError = null;
    notifyListeners();
  }

  /// Колбэк нативного туннеля: не выставляем [VpnConnectionState.connected] до [ _connectStageOnSuccess].
  void _onNativeVpnLinkChanged(bool nativeUp) {
    if (!nativeUp) {
      if (_currentState == VpnConnectionState.connected) {
        _stopTrafficStatsMonitoring();
        _applyTransition(VpnConnectionState.disconnected);
      } else {
        notifyListeners();
      }
      return;
    }
    notifyListeners();
  }

  String? get deviceId => _deviceId;
  Server? get selectedServer => _selectedServer;
  VpnProtocol get selectedProtocol => _selectedProtocol;
  DateTime? get connectionStartTime => _connectionStartTime;
  List<Server> get servers => _servers;
  String? get currentIpAddress => _currentIpAddress;
  String? get lastError => _lastError;
  int get totalBytesReceived => _totalBytesReceived;
  int get totalBytesSent => _totalBytesSent;

  /// Текущая скорость в Мбит/с (download + upload), обновляется каждую секунду при подключении
  double? get currentSpeedMbps => _currentSpeedMbps;

  /// Был ли хотя бы раз зафиксирован трафик (rx или tx > 0) — для отображения «Соединение стабильно» вместо «0 Мбит/с»
  bool get hasEverSeenTraffic => _hasEverSeenTraffic;
  bool get postConnectConnectivityDegraded => _postConnectConnectivityDegraded;
  String? get postConnectDegradedReason => _postConnectDegradedReason;
  bool get isXrayAvailable => _xrayAvailable;

  bool get _isXrayProtocol => _selectedProtocol.isXray;

  bool get _isGraniWgProtocol => _selectedProtocol == VpnProtocol.graniwg;

  bool _authAccessTokenRefreshHookRegistered = false;

  /// После refresh access token: сверка Dart↔native и мягкий /vpn/status (не рвём туннель).
  void _onAuthAccessTokenRefreshed() {
    _log(
        'VpnService: access token refreshed — sync native + server if connected');
    Future<void>(() async {
      try {
        if (_ignoreNetworkChangeUntil != null &&
            DateTime.now().isBefore(_ignoreNetworkChangeUntil!)) {
          _log(
              'VpnService._onAuthAccessTokenRefreshed: skip (grace period after resume)');
          return;
        }
        await syncConnectionStateWithNative();
        if (_deviceId == null || !_isConnected) return;
        final nativeUp = await NativeVpnService.getNativeConnectionStatus();
        if (nativeUp != true) {
          _log(
              'VpnService._onAuthAccessTokenRefreshed: native VPN не подтверждён — skip /vpn/status');
          return;
        }
        // Не шлём «живой» статус на сервер, если туннель давно без rx/tx (часто полудохлое состояние после смены сети).
        var allowServerSync = true;
        try {
          final start = _connectionStartTime;
          if (start != null &&
              DateTime.now().difference(start) > const Duration(seconds: 45)) {
            final stats = await NativeVpnService.getTrafficStats();
            final rx = (stats['rx_bytes'] ?? 0) as num;
            final tx = (stats['tx_bytes'] ?? 0) as num;
            if (rx == 0 && tx == 0) {
              allowServerSync = false;
              _log(
                'VpnService._onAuthAccessTokenRefreshed: нет трафика >45s — пропускаем /vpn/status (только UI sync)',
              );
            }
          }
        } catch (e) {
          _log('VpnService._onAuthAccessTokenRefreshed: traffic check: $e');
        }
        if (allowServerSync) {
          await _syncConnectionState(force: false);
        }
      } catch (e) {
        _log('VpnService._onAuthAccessTokenRefreshed: $e');
      }
    });
  }

  void _ensureAuthAccessTokenRefreshHook() {
    if (_authAccessTokenRefreshHookRegistered) return;
    _authAccessTokenRefreshHookRegistered = true;
    _authService.addAccessTokenRefreshedListener(_onAuthAccessTokenRefreshed);
  }

  /// Единый флаг «идёт connect-транзакция» для блокировки фоновых control-plane запросов.
  bool _isConnectFlowGateActive() {
    return _connectInProgress ||
        _isConnecting ||
        VpnOrchestrationRuntime.instance.isConnectTransactionActive;
  }

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

  void _setError(String? message) {
    _lastError = message;
  }

  Future<void> _refreshXrayAvailability() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      _xrayAvailable = false;
      return;
    }
    try {
      _xrayAvailable = await NativeVpnService.isXrayAvailable();
    } catch (e) {
      _xrayAvailable = false;
      _log('VpnService._refreshXrayAvailability: Ошибка проверки Xray: $e');
    }
    notifyListeners();
  }

  Future<void> _initialize() async {
    try {
      await _loadDeviceId();
      await _refreshXrayAvailability();

      // Максимально рано: если туннель уже поднят (приложение перезапущено при работающем VPN).
      await _restoreConnectionStateFromNative();

      // Инициализируем ConnectionLogger
      _connectionLogger.onDeviceIdResolved = _onDeviceIdResolvedByLogger;
      await _connectionLogger.initialize();

      // Сначала пытаемся загрузить из кэша для быстрого отображения
      await _loadServersFromCache();

      // Ожидаем загрузку токена с несколькими попытками
      int attempts = 0;
      const maxAttempts = 5;
      bool tokenLoaded = false;

      while (attempts < maxAttempts) {
        final token = await _getAuthToken();
        if (token != null && token.isNotEmpty) {
          _logger.debug('Токен найден на попытке ${attempts + 1}');
          tokenLoaded = true;
          // После перезапуска/краша device_id должен быть загружен из хранилища до любых API-запросов
          if (_deviceId == null) await _loadDeviceId();
          if (_deviceId != null) {
            _connectionLogger.setCredentials(token, _deviceId!);
          }
          await refreshServers();
          // Регистрация устройства при холодном старте (один раз за запуск)
          try {
            await ensureDeviceRegistered(token, verifyQuota: true);
          } on DeviceLimitException catch (e) {
            _logger
                .debug('Лимит устройств при регистрации (холодный старт): $e');
          } catch (e) {
            _logger
                .debug('Ошибка регистрации устройства при инициализации: $e');
          }
          // Кардинальное сокращение control-plane шума:
          // prewarm отключён, prepare/create выполняем только на реальном connect.
          break;
        }
        await Future.delayed(const Duration(milliseconds: 500));
        attempts++;
      }

      // Сверка с сервером только в фоне — не блокирует кнопку «подключено» при уже работающем туннеле.
      if (tokenLoaded && _deviceId != null) {
        _syncConnectionState().catchError((Object e) {
          _log('VpnService._initialize: фоновая _syncConnectionState: $e');
        });
      }

      // Если токен так и не появился, но есть кэш - используем его
      if (!tokenLoaded && _servers.isEmpty) {
        _logger.debug('Токен не найден, но есть кэш - используем его');
        await _loadServersFromCache();
      }

      _logger.info(
          'Инициализация завершена, загружено серверов: ${_servers.length}');
    } catch (e, stackTrace) {
      _logger.error(
          'Ошибка инициализации VPN сервиса', 'VpnService', e, stackTrace);
      // Продолжаем работу, серверы можно загрузить позже
    } finally {
      _listenNativeVpnState();
    }
  }

  // REGRESSION_NATIVE_VPN (ручная проверка после правок EventChannel / трафика):
  // - плитка быстрого доступа: вкл/выкл и UI;
  // - отзыв разрешения VPN в настройках;
  // - kill процесса приложения при активном туннеле;
  // - Wi‑Fi ↔ LTE, долгий фон: тики трафика реже (4 с), после resume — чаще (1 с);
  // - при отсутствии нативных событий ≥60 с — одна сверка [syncConnectionStateWithNative].

  /// Подписка на нативные события VPN (EventChannel), без периодического [getStatus].
  void _listenNativeVpnState() {
    _nativeVpnStateSubscription?.cancel();
    _nativeVpnStateSubscription = NativeVpnService.nativeVpnStateEvents.listen(
      _onNativeVpnStateEvent,
      onError: (Object e) => _log('VpnService nativeVpnState stream error: $e'),
    );
  }

  Future<void> _onNativeVpnStateEvent(Map<dynamic, dynamic> event) async {
    if (_isConnected) {
      _touchNativeConnectedSafetyPoll();
    }
    final emitType = event['emit_type']?.toString() ?? 'state';
    if (emitType == 'connectivity_probe') {
      _onNativeConnectivityProbe(event);
      return;
    }
    if (emitType == 'runtime_diag') {
      _onNativeRuntimeDiag(event);
      return;
    }
    if (emitType == 'traffic') {
      if (_isConnected) {
        _applyTrafficSnapshotFromNative(event);
      }
      return;
    }

    final connected = event['connected'] == true;
    try {
      if (_autoReconnectEnabled && _isConnected && !connected) {
        await _handleNativeDownForReconnect();
        return;
      }
      await syncConnectionStateWithNative();
    } catch (e) {
      _log('VpnService._onNativeVpnStateEvent: $e');
    }
  }

  int _intFromNativeVpnEvent(Map<dynamic, dynamic> event, String key) {
    final v = event[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 0;
  }

  /// Обновление rx/tx и скорости из нативного тика ([emit_type] == traffic), без MethodChannel getTrafficStats.
  void _applyTrafficSnapshotFromNative(Map<dynamic, dynamic> event) {
    try {
      _totalBytesReceived = _intFromNativeVpnEvent(event, 'rx_bytes');
      _totalBytesSent = _intFromNativeVpnEvent(event, 'tx_bytes');
      if (_totalBytesReceived > 0 || _totalBytesSent > 0) {
        if (!_hasEverSeenTraffic) {
          _hasEverSeenTraffic = true;
          _log(
            'VpnService: [VPN_TRAFFIC] Трафик через туннель зафиксирован (rx=$_totalBytesReceived, tx=$_totalBytesSent)',
          );
          if (_deviceId != null) {
            _connectionLogger.logTrafficFirstSeen(
              deviceId: _deviceId!,
              protocol: _selectedProtocol.apiValue,
              rxBytes: _totalBytesReceived,
              txBytes: _totalBytesSent,
              clientId: _clientId,
              serverId: _selectedServer != null
                  ? int.tryParse(_selectedServer!.id)
                  : null,
              connectionSessionId: _connectionSessionId,
              trigger: _connectionTrigger,
            );
          }
        }
      }
      final now = DateTime.now();
      final totalBytes = _totalBytesReceived + _totalBytesSent;
      if (_prevTrafficStatsTime != null) {
        final elapsedSec =
            now.difference(_prevTrafficStatsTime!).inMilliseconds / 1000.0;
        if (elapsedSec > 0) {
          _currentSpeedMbps =
              ((totalBytes - _prevTotalBytesForSpeed) * 8 / 1e6) / elapsedSec;
        }
      }
      _prevTotalBytesForSpeed = totalBytes;
      _prevTrafficStatsTime = now;
      notifyListeners();
    } catch (e) {
      _log('VpnService: Ошибка разбора native traffic event: $e');
    }
  }

  void _onNativeConnectivityProbe(Map<dynamic, dynamic> event) {
    final did = _deviceId;
    if (did == null) return;
    final rawCorr = event['correlation_session']?.toString();
    final correlationSessionId =
        (rawCorr != null && rawCorr.isNotEmpty) ? rawCorr : null;
    final boundRaw = event['vpn_transport_bound'];
    final vpnTransportBound =
        boundRaw == true || boundRaw == 1 || boundRaw == '1';
    final attemptsRaw = event['public_probe_attempts'];
    final publicProbeAttempts = attemptsRaw is int
        ? attemptsRaw
        : (attemptsRaw is num
            ? attemptsRaw.toInt()
            : int.tryParse(attemptsRaw?.toString() ?? ''));
    final publicOk = event['public_ok'] == true;
    final apiOk = event['api_ok'] == true;
    final publicErr = (event['public_err']?.toString() ?? '').toLowerCase();
    final apiErr = (event['api_err']?.toString() ?? '').toLowerCase();
    final publicFailureClass = _classifyProbeFailure(publicErr);
    final apiFailureClass = _classifyProbeFailure(apiErr);
    final epremProbe = ((publicErr.contains('binding socket to network') &&
            (publicErr.contains('eperm') ||
                publicErr.contains('operation not permitted'))) ||
        (apiErr.contains('binding socket to network') &&
            (apiErr.contains('eperm') ||
                apiErr.contains('operation not permitted'))));
    final hasActiveProxy = _hasActiveProxyTunneling();
    _lastConnectivityProbeAt = DateTime.now();
    _postConnectPublicOk = publicOk;
    _postConnectApiOk = apiOk;
    if (publicOk && apiOk) {
      _postConnectFailedProbeCount = 0;
      _postConnectFirstFailedProbeAt = null;
      _postConnectConnectivityDegraded = false;
      _postConnectDegradedReason = null;
    } else {
      _postConnectFailedProbeCount += 1;
      _postConnectFirstFailedProbeAt ??= DateTime.now();
      if (!publicOk && apiOk && _hasEverSeenTraffic) {
        _markPostConnectConnectivityDegraded(
          reason: 'public_internet_${publicFailureClass}_api_ok_traffic_seen',
        );
      } else if (epremProbe && _hasEverSeenTraffic && hasActiveProxy) {
        _markPostConnectConnectivityDegraded(
          reason: 'public_probe_eprem_proxy_tunneling_seen',
        );
      }
    }

    _connectionLogger.logConnectivityProbe(
      deviceId: did,
      protocol: _selectedProtocol.apiValue,
      vpnTransportBound: vpnTransportBound,
      publicOk: publicOk,
      publicRttMs: _intFromNativeVpnEvent(event, 'public_rtt_ms'),
      publicHttpStatus: _intFromNativeVpnEvent(event, 'public_http_status'),
      publicErr: event['public_err']?.toString(),
      publicFailureClass: publicFailureClass,
      publicUrlUsed: event['public_url']?.toString(),
      publicLabelUsed: event['public_label']?.toString(),
      publicProbeAttempts: publicProbeAttempts,
      apiOk: apiOk,
      apiRttMs: _intFromNativeVpnEvent(event, 'api_rtt_ms'),
      apiHttpStatus: _intFromNativeVpnEvent(event, 'api_http_status'),
      apiErr: event['api_err']?.toString(),
      apiFailureClass: apiFailureClass,
      correlationSessionId: correlationSessionId,
      clientId: _clientId,
      serverId:
          _selectedServer != null ? int.tryParse(_selectedServer!.id) : null,
      connectionSessionId: _connectionSessionId,
      trigger: _connectionTrigger,
    );
    _logDatapathCheckpoint(
      source: 'connectivity_probe',
      eventName: event['status']?.toString() ?? 'probe',
      payload: <String, dynamic>{
        'vpn_transport_bound': vpnTransportBound ? 1 : 0,
        'public_probe_attempts': publicProbeAttempts ?? -1,
        'public_failure_class': publicFailureClass,
        'api_failure_class': apiFailureClass,
        'public_http_status':
            _intFromNativeVpnEvent(event, 'public_http_status'),
        'api_http_status': _intFromNativeVpnEvent(event, 'api_http_status'),
      },
    );
    _maybeFinalizePostConnectCommit();
    final publicProbeExhausted =
        publicProbeAttempts != null && publicProbeAttempts >= 3;
    if (_isConnected &&
        !publicOk &&
        !_isDisconnecting &&
        (publicProbeExhausted ||
            _postConnectFailedProbeCount >= _postConnectMinFailedProbeCount)) {
      if (apiOk && _hasEverSeenTraffic) {
        _log(
          'VpnService: connectivity probe public internet degraded; keeping VPN connected '
          'public_ok=$publicOk api_ok=$apiOk traffic_seen=$_hasEverSeenTraffic attempts=${publicProbeAttempts ?? -1} '
          'failure_class=$publicFailureClass failed_probe_count=$_postConnectFailedProbeCount',
        );
        _markPostConnectConnectivityDegraded(
          reason: 'public_internet_${publicFailureClass}_api_ok_traffic_seen',
        );
      } else if (epremProbe && _hasEverSeenTraffic && hasActiveProxy) {
        _log(
          'VpnService: connectivity probe EPERM on VPN network bind; keeping VPN connected '
          'public_ok=$publicOk api_ok=$apiOk traffic_seen=$_hasEverSeenTraffic attempts=${publicProbeAttempts ?? -1} '
          'failure_class=$publicFailureClass failed_probe_count=$_postConnectFailedProbeCount',
        );
        _markPostConnectConnectivityDegraded(
          reason: 'public_probe_eprem_proxy_tunneling_seen',
        );
      } else {
        _log(
          'VpnService: connectivity probe hard failure; forcing disconnect '
          'public_ok=$publicOk api_ok=$apiOk traffic_seen=$_hasEverSeenTraffic attempts=${publicProbeAttempts ?? -1} '
          'failure_class=$publicFailureClass failed_probe_count=$_postConnectFailedProbeCount',
        );
        unawaited(_disconnectAfterConnectivityCommitFailure());
      }
    }
    _connectionLogger.scheduleFlushAfter(const Duration(seconds: 2));
  }

  bool _hasActiveProxyTunneling() {
    final outbounds = (_cachedEffectiveOutbounds ?? '').toLowerCase();
    if (outbounds.isEmpty) return false;
    return outbounds.contains('proxy/') || outbounds.contains('->proxy');
  }

  String _classifyProbeFailure(String errorText) {
    if (errorText.isEmpty) return 'none';
    if (errorText.contains('unknownhost') ||
        errorText.contains('unable to resolve host') ||
        errorText.contains('name or service not known') ||
        errorText.contains('no address associated')) {
      return 'dns_error';
    }
    if (errorText.contains('ssl') ||
        errorText.contains('tls') ||
        errorText.contains('handshake')) {
      return 'tls_error';
    }
    if (errorText.contains('connection refused') ||
        errorText.contains('connect failed')) {
      return 'tcp_refused';
    }
    if (errorText.contains('timed out') || errorText.contains('timeout')) {
      return 'timeout';
    }
    if (errorText.contains('network is unreachable') ||
        errorText.contains('no route to host')) {
      return 'network_unreachable';
    }
    return 'other';
  }

  String _datapathLayerForEvent(String eventName) {
    final normalized = eventName.trim().toLowerCase();
    if (normalized.isEmpty) return 'unknown';
    if (normalized == 'runtime_fail') return 'runtime';
    if (normalized == 'tun_state' ||
        normalized.contains('tun2socks') ||
        normalized.contains('closed_pipe') ||
        normalized.contains('cleanup_tun')) {
      return 'tun2socks_bridge';
    }
    if (normalized.contains('xray')) return 'libxray';
    return 'native';
  }

  void _logDatapathCheckpoint({
    required String source,
    required String eventName,
    Map<String, dynamic>? payload,
  }) {
    final did = _deviceId;
    if (did == null) return;
    final serverId =
        _selectedServer != null ? int.tryParse(_selectedServer!.id) : null;
    final details = <String, dynamic>{
      'checkpoint_source': source,
      'checkpoint_event': eventName,
      'checkpoint_seq': ++_datapathCheckpointSeq,
      'datapath_layer': _datapathLayerForEvent(eventName),
      'tun_rx_bytes': _totalBytesReceived,
      'tun_tx_bytes': _totalBytesSent,
      'traffic_seen': _hasEverSeenTraffic,
      'public_ok': _postConnectPublicOk == true,
      'api_ok': _postConnectApiOk == true,
      'failed_probe_count': _postConnectFailedProbeCount,
      if (_lastConnectivityProbeAt != null)
        'probe_age_ms':
            DateTime.now().difference(_lastConnectivityProbeAt!).inMilliseconds,
      if (_lastRuntimeCorrelationId != null &&
          _lastRuntimeCorrelationId!.isNotEmpty)
        'runtime_correlation_id': _lastRuntimeCorrelationId,
      if (_cachedEffectiveOutbounds != null &&
          _cachedEffectiveOutbounds!.isNotEmpty)
        'effective_outbounds': _cachedEffectiveOutbounds,
    };
    if (payload != null && payload.isNotEmpty) {
      details.addAll(payload);
    }
    _connectionLogger.logConnectionStage(
      deviceId: did,
      protocol: _selectedProtocol.apiValue,
      stage: 'datapath_checkpoint',
      clientId: _clientId,
      serverId: serverId,
      connectionSessionId: _connectionSessionId,
      trigger: _connectionTrigger,
      extraDetails: details,
    );
  }

  void _resetPostConnectCommitState() {
    _postConnectCommitTimer?.cancel();
    _postConnectCommitTimer = null;
    _postConnectCommitLogged = false;
    _postConnectPublicOk = null;
    _postConnectApiOk = null;
    _postConnectConnectivityDegraded = false;
    _postConnectDegradedReason = null;
    _lastConnectivityProbeAt = null;
    _postConnectFirstFailedProbeAt = null;
    _postConnectFailedProbeCount = 0;
    _datapathCheckpointSeq = 0;
  }

  void _startPostConnectCommitWatch() {
    _resetPostConnectCommitState();
    if (_minimalVpnMode) {
      _postConnectCommitLogged = true;
      _log(
          'VpnService.minimal_mode: post-connect commit watchdog disabled; local tunnel stays connected unless user disconnects');
      return;
    }
    _postConnectCommitTimer =
        Timer(_postConnectCommitWindow, _maybeFinalizePostConnectCommit);
  }

  bool _isStrictConnectivityCommitted() {
    final probeAt = _lastConnectivityProbeAt;
    final probeFresh = probeAt != null &&
        DateTime.now().difference(probeAt) <= _postConnectProbeFreshness;
    return _hasEverSeenTraffic &&
        probeFresh &&
        _postConnectPublicOk == true &&
        _postConnectApiOk == true;
  }

  bool _shouldAbortStrictConnectivityCommit() {
    final timerExpired = !(_postConnectCommitTimer?.isActive ?? false);
    if (!timerExpired) return false;
    // Never hard-abort when dataplane probe is already green.
    // API/DNS health can be transiently degraded right after connect.
    if (_postConnectPublicOk == true) return false;
    if (_postConnectApiOk == true && _hasEverSeenTraffic) return false;
    if (_hasEverSeenTraffic && _hasActiveProxyTunneling()) return false;
    final firstFailAt = _postConnectFirstFailedProbeAt;
    final retryWindowPassed = firstFailAt != null &&
        DateTime.now().difference(firstFailAt) >= _postConnectMinRetryWindow;
    return _postConnectFailedProbeCount >= _postConnectMinFailedProbeCount &&
        retryWindowPassed;
  }

  void _markPostConnectConnectivityDegraded({required String reason}) {
    _postConnectConnectivityDegraded = true;
    _postConnectDegradedReason = reason;
    _setError(
        'degraded_connectivity: public internet probe failed, API health and VPN traffic are ok.');
    _connectionLogger.logConnectionStage(
      deviceId: _deviceId!,
      protocol: _selectedProtocol.apiValue,
      stage: 'connected_degraded_retry',
      clientId: _clientId,
      serverId:
          _selectedServer != null ? int.tryParse(_selectedServer!.id) : null,
      connectionSessionId: _connectionSessionId,
      trigger: _connectionTrigger,
      extraDetails: {
        'reason': reason,
        'traffic_seen': _hasEverSeenTraffic,
        'public_ok': _postConnectPublicOk == true,
        'api_ok': _postConnectApiOk == true,
        'failed_probe_count': _postConnectFailedProbeCount,
        'action': 'keep_connected_retry_public_probe',
      },
    );
    _connectionLogger.scheduleFlushAfter(const Duration(seconds: 1));
    notifyListeners();
  }

  void _maybeFinalizePostConnectCommit() {
    if (_postConnectCommitLogged || !_isConnected || _deviceId == null) return;
    final serverId =
        _selectedServer != null ? int.tryParse(_selectedServer!.id) : null;
    final committed = _isStrictConnectivityCommitted();
    if (committed) {
      _postConnectCommitLogged = true;
      _connectionLogger.logConnectionSuccess(
        deviceId: _deviceId!,
        protocol: _selectedProtocol.apiValue,
        clientId: _clientId,
        serverId: serverId,
        connectionDurationMs: _connectionStartTime == null
            ? null
            : DateTime.now().difference(_connectionStartTime!).inMilliseconds,
        connectionSessionId: _connectionSessionId,
        trigger: _connectionTrigger,
        trafficVerified: true,
        connectionFlowType: _connectionFlowType.name,
      );
      _connectionLogger.logConnectionStage(
        deviceId: _deviceId!,
        protocol: _selectedProtocol.apiValue,
        stage: 'connected_validated',
        clientId: _clientId,
        serverId: serverId,
        connectionSessionId: _connectionSessionId,
        trigger: _connectionTrigger,
      );
      _connectionLogger.scheduleFlushAfter(const Duration(seconds: 1));
      return;
    }
    if ((_postConnectPublicOk == true) ||
        (_postConnectApiOk == true && _hasEverSeenTraffic) ||
        (_hasEverSeenTraffic && _hasActiveProxyTunneling())) {
      _markPostConnectConnectivityDegraded(
        reason: (_postConnectPublicOk == true)
            ? 'commit_window_expired_api_probe_failed_public_ok'
            : (_postConnectApiOk == true)
                ? 'commit_window_expired_public_probe_failed_api_ok_traffic_seen'
                : 'commit_window_expired_public_probe_failed_proxy_tunneling_seen',
      );
      return;
    }
    // Fail commit only after retry window with repeated failed probes.
    if (!_shouldAbortStrictConnectivityCommit()) return;
    _postConnectCommitLogged = true;
    final reasonClass = _classifyCommitFailureReason(
      publicOk: _postConnectPublicOk == true,
      apiOk: _postConnectApiOk == true,
      trafficSeen: _hasEverSeenTraffic,
    );
    _connectionLogger.logConnectionError(
      deviceId: _deviceId!,
      protocol: _selectedProtocol.apiValue,
      errorMessage: 'connectivity_commit_failed',
      errorCode: reasonClass,
      clientId: _clientId,
      serverId: serverId,
      errorDetails: _buildCommitFailureBundle(reasonClass)
        ..['retry_window_ms'] = _postConnectMinRetryWindow.inMilliseconds,
      connectionSessionId: _connectionSessionId,
      trigger: _connectionTrigger,
    );
    _connectionLogger.scheduleFlushAfter(const Duration(seconds: 1));
    if (_isConnected && !_isDisconnecting) {
      unawaited(_disconnectAfterConnectivityCommitFailure());
    }
  }

  void _scheduleMtuFallbackForDegradedConnectivity() {
    final next = _nextFallbackMtu(_lastNetworkType, _lastMtu);
    if (next == null || next == _lastMtu) return;
    _pendingMtuOverride = next;
    _pendingMtuReason = 'degraded_connectivity';
    _log(
      'VpnService: scheduling MTU fallback override next_connect_mtu=$next '
      '(current=$_lastMtu network=${_lastNetworkType ?? "unknown"})',
    );
  }

  Future<void> _disconnectAfterConnectivityCommitFailure() async {
    _scheduleMtuFallbackForDegradedConnectivity();
    final publicOk = _postConnectPublicOk == true;
    final apiOk = _postConnectApiOk == true;
    final reasonClass = _classifyCommitFailureReason(
      publicOk: publicOk,
      apiOk: apiOk,
      trafficSeen: _hasEverSeenTraffic,
    );
    final errorMessage = (!publicOk && apiOk)
        ? 'public_probe_timeout: публичный интернет недоступен через туннель.'
        : (!publicOk && !apiOk)
            ? 'node_unreachable: нет ответа от публичного интернета и API через туннель.'
            : 'connectivity_commit_failed: apply подтвержден, но трафик нестабилен.';
    _log(
      'VpnService: strict connectivity commit failed, keeping tunnel up '
      'session=${_connectionSessionId ?? "-"} reason_class=$reasonClass',
    );
    _setError(errorMessage);
    _log(
      'VpnService: connectivity_commit_gate stop suppressed by disconnect policy '
      'source=connectivity_commit_gate:$reasonClass',
    );
    notifyListeners();
  }

  void _onNativeRuntimeDiag(Map<dynamic, dynamic> event) {
    final did = _deviceId;
    if (did == null) return;
    final eventName = event['event_name']?.toString() ?? 'native_runtime_diag';
    final details = <String, dynamic>{};
    for (final entry in event.entries) {
      final key = entry.key?.toString();
      if (key == null) continue;
      if (key == 'emit_type' || key == 'event_name') continue;
      details[key] = entry.value;
    }
    _lastNativeRuntimeDiag = Map<String, dynamic>.from(details);
    _lastNativeRuntimeDiagAt = DateTime.now();
    final outboundsRaw = details['effective_outbounds']?.toString();
    if (outboundsRaw != null && outboundsRaw.trim().isNotEmpty) {
      _cachedEffectiveOutbounds = outboundsRaw.trim();
    }
    final serverId =
        _selectedServer != null ? int.tryParse(_selectedServer!.id) : null;
    if (eventName == 'runtime_fail') {
      _connectionLogger.logConnectionError(
        deviceId: did,
        protocol: _selectedProtocol.apiValue,
        errorMessage:
            (event['runtime_fail_reason'] ?? event['reason'] ?? 'runtime_fail')
                .toString(),
        errorCode: 'runtime_fail',
        clientId: _clientId,
        serverId: serverId,
        errorDetails: details,
        connectionSessionId: _connectionSessionId,
        trigger: _connectionTrigger,
      );
    } else {
      _connectionLogger.logConnectionError(
        deviceId: did,
        protocol: _selectedProtocol.apiValue,
        errorMessage: 'native_$eventName',
        errorCode: 'native_runtime_diag',
        clientId: _clientId,
        serverId: serverId,
        errorDetails: details,
        connectionSessionId: _connectionSessionId,
        trigger: _connectionTrigger,
      );
    }
    _logDatapathCheckpoint(
      source: 'runtime_diag',
      eventName: eventName,
      payload: details,
    );
    _connectionLogger.scheduleFlushAfter(const Duration(seconds: 1));
  }

  String _classifyCommitFailureReason({
    required bool publicOk,
    required bool apiOk,
    required bool trafficSeen,
  }) {
    return classifyCommitFailureReasonForTest(
      publicOk: publicOk,
      apiOk: apiOk,
      trafficSeen: trafficSeen,
    );
  }

  Map<String, dynamic> _buildCommitFailureBundle(String reasonClass) {
    return buildCommitFailureBundleForTest(
      reasonClass: reasonClass,
      trafficSeen: _hasEverSeenTraffic,
      publicOk: _postConnectPublicOk == true,
      apiOk: _postConnectApiOk == true,
      failedProbeCount: _postConnectFailedProbeCount,
      connectionSessionId: _connectionSessionId,
      trigger: _connectionTrigger,
      effectiveOutbounds: _cachedEffectiveOutbounds,
      probeAt: _lastConnectivityProbeAt,
      runtimeDiagAt: _lastNativeRuntimeDiagAt,
      runtimeDiag: _lastNativeRuntimeDiag,
      now: DateTime.now(),
    );
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

  Map<String, dynamic>? _runtimeContractServerExpectation() {
    final rc = _lastRuntimeContract;
    if (rc == null) return null;
    final raw = rc['server_expectation'];
    if (raw is! Map) return null;
    return Map<String, dynamic>.from(raw);
  }

  Map<String, String>? _parseProxyOutbound(String effectiveOutbounds) {
    final parts = effectiveOutbounds
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty);
    for (final part in parts) {
      final tokens = part.split('/');
      if (tokens.length < 4) continue;
      if (tokens[0].trim().toLowerCase() != 'proxy') continue;
      final addressPort = tokens[2].trim();
      final idx = addressPort.lastIndexOf(':');
      if (idx <= 0 || idx >= addressPort.length - 1) continue;
      return <String, String>{
        'protocol': tokens[1].trim().toLowerCase(),
        'host': addressPort.substring(0, idx).trim(),
        'port': addressPort.substring(idx + 1).trim(),
        'security': tokens[3].trim().toLowerCase(),
      };
    }
    return null;
  }

  String _normalizeContractSecurity(dynamic tlsRaw) {
    final tls = (tlsRaw ?? '').toString().trim().toLowerCase();
    if (tls.isEmpty) return 'none';
    if (tls == 'none') return 'none';
    if (tls == 'reality') return 'reality';
    return tls;
  }

  Future<void> _enforceRuntimeContractAgainstEffectiveOutbounds() async {
    if (!_isXrayProtocol || !Platform.isAndroid) return;
    final expectation = _runtimeContractServerExpectation();
    if (expectation == null || expectation.isEmpty) return;

    final expectedHost = (expectation['host'] ?? '').toString().trim();
    final expectedPort = (expectation['port'] ?? '').toString().trim();
    final expectedSecurity = _normalizeContractSecurity(expectation['tls']);
    final expectedProtocol = (_lastRuntimeContract?['protocol'] ?? '')
        .toString()
        .trim()
        .toLowerCase();

    String? effectiveOutbounds = _cachedEffectiveOutbounds;
    if (effectiveOutbounds == null || effectiveOutbounds.isEmpty) {
      for (var i = 0; i < 3; i++) {
        final fetched = await NativeVpnService.getEffectiveOutbounds();
        if (fetched != null && fetched.isNotEmpty) {
          effectiveOutbounds = fetched;
          _cachedEffectiveOutbounds = fetched;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
    if (effectiveOutbounds == null || effectiveOutbounds.isEmpty) return;

    final proxy = _parseProxyOutbound(effectiveOutbounds);
    if (proxy == null) return;
    final mismatchFields = <String>[];
    final effectiveProtocol = proxy['protocol'] ?? '';
    final effectiveSecurity = proxy['security'] ?? '';
    final protocolMatches = expectedProtocol.isEmpty ||
        effectiveProtocol == expectedProtocol ||
        (expectedProtocol == 'reality' &&
            effectiveProtocol == 'vless' &&
            effectiveSecurity == 'reality');
    if (!protocolMatches) {
      mismatchFields.add('protocol');
    }
    if (expectedHost.isNotEmpty && proxy['host'] != expectedHost) {
      mismatchFields.add('host');
    }
    if (expectedPort.isNotEmpty && proxy['port'] != expectedPort) {
      mismatchFields.add('port');
    }
    if (expectedSecurity.isNotEmpty && proxy['security'] != expectedSecurity) {
      mismatchFields.add('tls');
    }
    if (mismatchFields.isEmpty) return;

    _log(
      'VpnService: runtime_contract_effective_mismatch '
      'correlation_id=${_lastRuntimeCorrelationId ?? "-"} fields=$mismatchFields',
    );
    if (_deviceId != null && _selectedServer != null) {
      _connectionLogger.logConnectionError(
        deviceId: _deviceId!,
        protocol: _selectedProtocol.apiValue,
        errorMessage: 'runtime_contract_effective_mismatch',
        errorCode: 'runtime_contract_mismatch',
        clientId: _clientId,
        serverId: int.tryParse(_selectedServer!.id),
        errorDetails: <String, dynamic>{
          'correlation_id': _lastRuntimeCorrelationId,
          'mismatch_fields': mismatchFields,
          'expected_protocol': expectedProtocol,
          'expected_host': expectedHost,
          'expected_port': expectedPort,
          'expected_tls': expectedSecurity,
          'effective_protocol': effectiveProtocol,
          'effective_host': proxy['host'],
          'effective_port': proxy['port'],
          'effective_tls': effectiveSecurity,
          'effective_outbounds': effectiveOutbounds,
        },
        connectionSessionId: _connectionSessionId,
        trigger: _connectionTrigger,
      );
    }
    throw Exception('Runtime contract mismatch after tunnel start');
  }

  /// Логика бывшего 10s-polling: обрыв туннеля при включённом auto-reconnect.
  Future<void> _handleNativeDownForReconnect() async {
    _log(
        'VpnService: нативный слой сообщил disconnect — переподключение (event-driven)');
    _applyTransition(VpnConnectionState.disconnected);
    _stopTrafficStatsMonitoring();

    if (_reconnectionAttempts < _maxReconnectionAttempts) {
      _reconnectionAttempts++;
      _log(
        'VpnService: Попытка переподключения $_reconnectionAttempts/$_maxReconnectionAttempts',
      );
      await Future.delayed(_reconnectionDelay);
      final success = await connect();
      if (success) {
        _log('VpnService: Переподключение успешно');
        _reconnectionAttempts = 0;
      } else {
        _log('VpnService: Переподключение не удалось');
      }
    } else {
      _log(
          'VpnService: Достигнуто максимальное количество попыток переподключения');
      _stopConnectionMonitoring();
      _autoReconnectEnabled = false;
    }
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

  Future<void> _loadDeviceId() async {
    try {
      final secureId = await _storageService.getSecureString('device_id');
      final cachedId = secureId ?? await _storageService.getString('device_id');

      if (cachedId != null && cachedId.isNotEmpty) {
        _deviceId = cachedId;
        if (secureId == null) {
          await _storageService.setSecureString('device_id', cachedId);
        }
        return;
      }

      // Нет локального device_id (переустановка/очистка): пробуем resolve по fingerprint
      final fingerprint = await _getDeviceFingerprint();
      if (fingerprint != null && fingerprint.isNotEmpty) {
        final token = await _storageService.getSecureString('auth_token') ??
            await _storageService.getString('auth_token');
        if (token != null && token.isNotEmpty) {
          final resolvedId =
              await _resolveDeviceIdFromServer(fingerprint, token);
          if (resolvedId != null && resolvedId.isNotEmpty) {
            _deviceId = resolvedId;
            await _storageService.setSecureString('device_id', _deviceId!);
            await _storageService.setString('device_id', _deviceId!);
            _logger.info('device_id восстановлен через resolve по fingerprint');
            return;
          }
        }
      }

      _deviceId = _generateDeviceId();
      await _storageService.setSecureString('device_id', _deviceId!);
      await _storageService.setString('device_id', _deviceId!);
    } catch (e) {
      _logger.error('Ошибка получения device_id', 'VpnService', e);
      _deviceId = 'unknown_${DateTime.now().millisecondsSinceEpoch}';
    }
  }

  /// Стабильный отпечаток устройства для resolve после переустановки (SHA-256 от id + bundle).
  Future<String?> _getDeviceFingerprint() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      final packageInfo = await PackageInfo.fromPlatform();
      final bundleId = packageInfo.packageName;
      String? rawId;
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        rawId =
            androidInfo.id; // Android ID, стабилен при переустановке приложения
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        rawId = iosInfo.identifierForVendor; // может быть null
      } else if (Platform.isWindows) {
        final winInfo = await deviceInfo.windowsInfo;
        rawId = winInfo.deviceId;
      } else if (Platform.isMacOS) {
        final macInfo = await deviceInfo.macOsInfo;
        rawId = macInfo.systemGUID;
      }
      if (rawId == null || rawId.isEmpty) return null;
      final combined = '$rawId#$bundleId';
      final bytes = utf8.encode(combined);
      final digest = sha256.convert(bytes);
      return digest.toString();
    } catch (e) {
      _logger.debug('Ошибка получения fingerprint устройства: $e');
      return null;
    }
  }

  /// Возвращает fingerprint устройства (кеширует после первого получения). Для register/connect.
  Future<String?> _getFingerprintForPayload() async {
    if (_cachedFingerprint != null && _cachedFingerprint!.isNotEmpty) {
      return _cachedFingerprint;
    }
    final fp = await _getDeviceFingerprint();
    if (fp != null && fp.isNotEmpty) {
      _cachedFingerprint = fp;
    }
    return fp;
  }

  /// Данные для POST /vpn/connect (server_id, protocol; device_id и fingerprint опциональны).
  /// Без device_id бэкенд использует единый алгоритм (один коннект на user+server+protocol).
  Future<Map<String, dynamic>> _connectPayload(String protocolValue) async {
    final data = <String, dynamic>{
      'server_id': int.parse(_selectedServer!.id),
      'protocol': protocolValue,
    };
    if (_deviceId != null && _deviceId!.isNotEmpty) {
      data['device_id'] = _deviceId;
    }
    final fp = await _getFingerprintForPayload();
    if (fp != null && fp.isNotEmpty) data['fingerprint'] = fp;
    return data;
  }

  Future<Options> _vpnApiOptions(
    Map<String, dynamic> headers, {
    bool readHeavy = false,
  }) async {
    final t = readHeavy
        ? await NetworkTimeouts.vpnApiReadHeavy()
        : await NetworkTimeouts.vpnApi();
    final extra = <String, dynamic>{
      'grani_connect_timeout': t.connect,
      'grani_send_timeout': t.send,
      'grani_receive_timeout': t.receive,
    };
    return Options(
      sendTimeout: t.send,
      receiveTimeout: t.receive,
      extra: extra,
      headers: headers,
    );
  }

  /// Запрос device_id по fingerprint (POST /api/vpn/device/resolve).
  Future<String?> _resolveDeviceIdFromServer(
      String fingerprint, String token) async {
    try {
      final response = await _apiClient.post(
        '/vpn/device/resolve',
        data: {'fingerprint': fingerprint},
        options: await _vpnApiOptions({
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Authorization': 'Bearer $token',
        }),
      );
      if (response.statusCode == 200 && response.data != null) {
        final deviceId = response.data!['device_id']?.toString();
        return deviceId;
      }
      return null;
    } catch (e) {
      _logger.debug('Resolve device_id не удался: $e');
      return null;
    }
  }

  /// Вызывается ConnectionLogger, когда device_id разрешён по fingerprint.
  /// Обновляет локальный _deviceId и сохраняет в хранилище.
  void _onDeviceIdResolvedByLogger(String newDeviceId) {
    _log(
        'VpnService: device_id обновлён через fingerprint resolve: $newDeviceId (был: $_deviceId)');
    _deviceId = newDeviceId;
    _storageService.setSecureString('device_id', newDeviceId);
    _storageService.setString('device_id', newDeviceId);
  }

  String _generateDeviceId() {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant RFC 4122

    String toHex(int value) => value.toRadixString(16).padLeft(2, '0');
    final hex = bytes.map(toHex).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  Future<String> _getNetworkTypeLabel() async {
    try {
      final dynamic result = await Connectivity().checkConnectivity();
      final List<ConnectivityResult> types = result is List
          ? List<ConnectivityResult>.from(result)
          : [result as ConnectivityResult];

      if (types.contains(ConnectivityResult.wifi)) return 'wifi';
      if (types.contains(ConnectivityResult.mobile)) return 'mobile';
      if (types.contains(ConnectivityResult.ethernet)) return 'ethernet';
      if (types.contains(ConnectivityResult.none)) return 'none';
      if (types.isNotEmpty) return types.first.name;
      return 'unknown';
    } catch (_) {
      return 'unknown';
    }
  }

  int _selectMtu(String? networkType) {
    switch (networkType) {
      case 'wifi':
      case 'ethernet':
        return _mtuWifi;
      case 'mobile':
        return _mtuMobile;
      case 'none':
      case 'unknown':
      default:
        return _mtuDefault;
    }
  }

  List<int> _mtuProfileForNetwork(String? networkType) {
    switch (networkType) {
      case 'mobile':
        return _mobileMtuFallbackProfile;
      case 'wifi':
      case 'ethernet':
        return _wifiMtuFallbackProfile;
      default:
        return <int>[_mtuDefault];
    }
  }

  int? _nextFallbackMtu(String? networkType, int? currentMtu) {
    final profile = _mtuProfileForNetwork(networkType);
    if (profile.isEmpty) return null;
    final currentIndex = currentMtu == null ? -1 : profile.indexOf(currentMtu);
    if (currentIndex < 0) return profile.first;
    if (currentIndex + 1 < profile.length) return profile[currentIndex + 1];
    return null;
  }

  /// Запуск слушателя смены сети: при Wi‑Fi ↔ mobile отключаемся и переподключаемся с правильным MTU.
  void _startNetworkChangeListener() {
    _stopNetworkChangeListener();
    _connectivitySubscription = Connectivity()
        .onConnectivityChanged
        .listen((List<ConnectivityResult> results) {
      if (!_isConnected || _isDisconnecting || _isConnecting) return;
      _networkChangeDebounce?.cancel();
      _networkChangeDebounce =
          Timer(AppConfig.networkChangeDebounceDuration, () async {
        _networkChangeDebounce = null;
        if (!_isConnected || _isDisconnecting || _isConnecting) return;
        final current = await _getNetworkTypeLabel();
        final atConnect = _lastNetworkType;
        if (atConnect == null || current == atConnect) return;
        const meaningful = ['wifi', 'mobile', 'ethernet'];
        if (!meaningful.contains(current) || !meaningful.contains(atConnect)) {
          return;
        }
        if (_lastReconnectConnectStartedAt != null) {
          final elapsed =
              DateTime.now().difference(_lastReconnectConnectStartedAt!);
          if (elapsed < AppConfig.reconnectMinIntervalAfterNetworkChange) {
            _log(
                'VpnService: [reconnect] смена сети пропущена (cooldown ${elapsed.inMilliseconds}ms < ${AppConfig.reconnectMinIntervalAfterNetworkChange.inMilliseconds}ms)');
            return;
          }
        }
        if (_ignoreNetworkChangeUntil != null &&
            DateTime.now().isBefore(_ignoreNetworkChangeUntil!)) {
          _log(
              'VpnService: [reconnect] смена сети пропущена (grace period после resume, как при закрытии приложения)');
          return;
        }
        _log('VpnService: [MONITOR] network_change $atConnect → $current');
        if (_deviceId != null) {
          _connectionLogger.logNetworkChange(
            deviceId: _deviceId!,
            networkFrom: atConnect,
            networkTo: current,
            protocol: _selectedProtocol.apiValue,
            clientId: _clientId,
            serverId: _selectedServer != null
                ? int.tryParse(_selectedServer!.id)
                : null,
            connectionSessionId: _connectionSessionId,
          );
        }
        if (Platform.isAndroid) {
          // На Android handover обрабатывается в GraniVpnService через native NetworkCallback.
          // Из Flutter логируем событие и обновляем lastNetworkType, чтобы не запускать
          // второй параллельный disconnect/connect цикл.
          _lastNetworkType = current;
          _log(
              'VpnService: [reconnect] Android native handover active, Flutter reconnect skipped');
          return;
        }
        _reconnectAfterNetworkChange = true;
        _log(
            'VpnService: [reconnect] disconnect() начат (reconnectAfterNetworkChange=true)');
        await disconnect(
          reason: VpnDisconnectReason.networkChangeReconnect,
          source: 'network_change_reconnect',
        );
      });
    });
  }

  void _stopNetworkChangeListener() {
    _networkChangeDebounce?.cancel();
    _networkChangeDebounce = null;
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
  }

  void _logConnectionStage({
    required String stage,
    required Stopwatch stopwatch,
    required String protocol,
    String? networkType,
    String? apiRouteUsed,
    int? apiRequestMs,
    String? disconnectReason,
    Map<String, dynamic>? extraDetails,
  }) {
    final durationMs = stopwatch.elapsedMilliseconds;
    _lastConnectionTimingMs[stage] = durationMs;
    if (_deviceId == null) {
      stopwatch
        ..reset()
        ..start();
      return;
    }
    _connectionLogger.logConnectionStage(
      deviceId: _deviceId!,
      protocol: protocol,
      stage: stage,
      durationMs: durationMs,
      networkType: networkType,
      clientId: _clientId,
      serverId:
          _selectedServer != null ? int.tryParse(_selectedServer!.id) : null,
      connectionSessionId: _connectionSessionId,
      trigger: _connectionTrigger,
      apiRouteUsed: apiRouteUsed,
      apiRequestMs: apiRequestMs,
      disconnectReason: disconnectReason,
      extraDetails: extraDetails,
    );
    stopwatch
      ..reset()
      ..start();
  }

  void _logConnectionTimingSummary(int totalMs, {String result = 'unknown'}) {
    final parts = _lastConnectionTimingMs.entries
        .map((e) => '${e.key}=${e.value}ms')
        .join(', ');
    _log(
      'VpnService.connect: [Connection timing] result=$result total_ms=$totalMs stages={$parts}',
    );
  }

  Future<void> selectProtocol(VpnProtocol protocol) async {
    if (_minimalVpnMode) {
      _selectedProtocol = _minimalVpnProtocol;
      _log(
          'VpnService.selectProtocol: ignored in minimal mode; forced protocol=${_selectedProtocol.apiValue}');
      notifyListeners();
      return;
    }
    // Если уже выбран тот же протокол, ничего не делаем
    if (_selectedProtocol == protocol && !_isConnected && !_isConnecting) {
      return;
    }

    // Если подключены или идет подключение/отключение, сначала отключаемся
    if (_isConnected || _isConnecting || _isDisconnecting) {
      _log('VpnService.selectProtocol: Отключаемся перед сменой протокола...');
      await disconnect(
        reason: VpnDisconnectReason.protocolSwitch,
        source: 'select_protocol',
      );

      // Ждём завершения отключения (макс. 8 с)
      int attempts = 0;
      while ((_isConnecting || _isConnected || _isDisconnecting) &&
          attempts < AppConfig.disconnectWaitConnectMaxAttempts) {
        await Future.delayed(AppConfig.disconnectWaitConnectStep);
        attempts++;
      }
      if (_isConnecting || _isConnected || _isDisconnecting) {
        _log(
            'VpnService.selectProtocol: ⚠️ Таймаут отключения 8 с — принудительный сброс состояния');
        try {
          await NativeVpnService.disconnect(
            reason: VpnDisconnectReason.protocolSwitch,
            source: 'select_protocol_force',
            connectionSessionId: _connectionSessionId,
          );
        } catch (e) {
          _log(
              'VpnService.selectProtocol: Ошибка принудительного отключения: $e');
        }
        _applyTransition(VpnConnectionState.disconnected);
      }
    }

    // Очищаем кэш конфигурации для старого протокола
    await _clearConfigCache();

    _selectedProtocol = protocol;
    notifyListeners();
    _log('VpnService.selectProtocol: Протокол изменен на ${protocol.name}');
    await _persistUserUiSelectionToStorage(reason: 'select_protocol');
  }

  /// Обновляет прогресс подключения
  void _updateProgress(ConnectionProgress progress) {
    _connectionProgress = progress;
    notifyListeners();
    _logger.debug(
        'Прогресс подключения: ${progress.percent}% - ${progress.message}');
  }

  void _setConnectionFlowType(ConnectionFlowType type) {
    if (_connectionFlowType == type) return;
    _connectionFlowType = type;
    _log('VpnService.connect: flow_type = ${type.name}');
    notifyListeners();
  }

  /// Автоматически выбирает оптимальный сервер и протокол
  Future<void> _autoSelectServerAndProtocol() async {
    _updateProgress(ConnectionProgress.autoSelectingServer);

    if (_minimalVpnMode) {
      if (_servers.isEmpty) {
        await refreshServers();
      }
      _forceMinimalVpnSelection(reason: 'auto_select');
      return;
    }

    // Если сервер не выбран, выбираем оптимальный
    if (_selectedServer == null) {
      if (_servers.isEmpty) {
        await refreshServers();
      }

      if (_servers.isNotEmpty) {
        // Выбираем первый активный сервер (можно улучшить логику выбора)
        _selectedServer = _servers.firstWhere(
          (s) => s.isActive == true,
          orElse: () => _servers.first,
        );
        _logger.debug('Автоматически выбран сервер: ${_selectedServer!.id}');
      }
    }

    // Если протокол не поддерживается сервером, выбираем лучший
    if (_selectedServer != null) {
      final protocolString = _selectedProtocol.apiValue;
      final supportedProtocols = _selectedServer!.supportedProtocols;

      if (supportedProtocols != null &&
          supportedProtocols.isNotEmpty &&
          !supportedProtocols.contains(protocolString)) {
        // Выбираем первый поддерживаемый протокол
        final bestProtocol = _findBestProtocol(_selectedServer!);
        if (bestProtocol != null) {
          _selectedProtocol = bestProtocol;
          _logger.debug(
              'Автоматически выбран протокол: ${_selectedProtocol.name}');
        }
      }
    }
  }

  void _forceMinimalVpnSelection({String reason = 'minimal'}) {
    if (!_minimalVpnMode) return;
    Server? minimalServer;
    for (final server in _servers) {
      if (server.id == _minimalVpnServerId && server.isActive) {
        minimalServer = server;
        break;
      }
    }
    minimalServer ??=
        _servers.where((s) => s.id == _minimalVpnServerId).isNotEmpty
            ? _servers.firstWhere((s) => s.id == _minimalVpnServerId)
            : null;
    if (minimalServer != null) {
      _selectedServer = minimalServer;
    } else if (_selectedServer == null && _servers.isNotEmpty) {
      _selectedServer = _servers.first;
      _log(
          'VpnService.minimal_mode: UK-LON-01 id=$_minimalVpnServerId not found; fallback server=${_selectedServer!.id}');
    }
    _selectedProtocol = _minimalVpnProtocol;
    _log(
        'VpnService.minimal_mode: reason=$reason server=${_selectedServer?.id ?? '-'} protocol=${_selectedProtocol.apiValue}');
  }

  /// Находит лучший протокол для сервера из его supportedProtocols
  VpnProtocol? _findBestProtocol(Server server) {
    final supported = server.supportedProtocols;
    if (supported == null || supported.isEmpty) {
      return VpnProtocol.graniwg;
    }
    if (supported.contains('graniwg')) {
      const p = VpnProtocol.graniwg;
      if (p.isImplemented) return p;
    }
    for (final proto in _xrayProtocolPriority) {
      if (supported.contains(proto)) {
        final protocol = _parseProtocolString(proto);
        if (protocol != null && protocol.isImplemented) {
          return protocol;
        }
      }
    }
    return VpnProtocol.graniwg;
  }

  /// Получает кэшированную конфигурацию.
  /// Xray — единый слой Storage (бессрочно), остальные — CacheService (5 мин).
  Future<String?> _getCachedConfig() async {
    if (_selectedServer == null) return null;

    try {
      if (_isXrayProtocol) {
        if (!_diagnosticAllowReconnectFromCache) {
          return null;
        }
        final cached = await _xrayConnectionHandler.getCachedConfig(
          _selectedServer!,
          _selectedProtocol,
        );
        if (cached != null) {
          _logger.debug('Используем кэшированную Xray конфигурацию из Storage');
          return cached.jsonConfig;
        }
        return null;
      }

      final cacheKey =
          'vpn_config_${_selectedServer!.id}_${_selectedProtocol.name}';
      final cached = await _cacheService.getString(cacheKey);
      if (cached != null && cached.isNotEmpty) {
        final isValid = await _cacheService.isValid(cacheKey);
        if (isValid && _isConfigValid(cached, _selectedProtocol)) {
          _logger.debug(
              'Используем кэшированную конфигурацию (возраст: ${await _cacheService.getAge(cacheKey) ?? 0} сек)');
          return cached;
        }
        if (!_isConfigValid(cached, _selectedProtocol)) {
          await _cacheService.remove(cacheKey);
        }
      }
    } catch (e) {
      _logger.error('Ошибка получения кэша конфигурации', 'VpnService', e);
    }
    return null;
  }

  /// Проверяет валидность конфигурации для указанного протокола
  bool _isConfigValid(String config, VpnProtocol protocol) {
    if (config.isEmpty) return false;

    if (protocol == VpnProtocol.graniwg) {
      final t = config.trim();
      return t.contains('[Interface]') && t.contains('[Peer]');
    }

    // Для XRay: проверяем JSON формат
    if (protocol == VpnProtocol.xrayVless ||
        protocol == VpnProtocol.xrayVmess ||
        protocol == VpnProtocol.xrayReality) {
      if (config.trim().startsWith('{')) {
        try {
          final json = jsonDecode(config);
          return json is Map && json.isNotEmpty;
        } catch (e) {
          return false;
        }
      }
      if (config.startsWith('vless://') || config.startsWith('vmess://')) {
        return config.length > 20;
      }
      return false;
    }

    return true;
  }

  /// Сохраняет конфигурацию в кэш. Xray — единый слой (Storage), остальные — CacheService.
  Future<void> _cacheConfig(String config, [String? clientId]) async {
    if (_selectedServer == null) return;
    try {
      if (_isXrayProtocol) {
        await _saveXrayConfigToStorage(config, clientId);
        _logger.debug('Xray конфиг сохранён в Storage (единый кэш)');
      } else {
        await _cacheService.setString(
          'vpn_config_${_selectedServer!.id}_${_selectedProtocol.name}',
          config,
          ttl: const Duration(minutes: 5),
        );
      }
    } catch (e) {
      _logger.error('Ошибка сохранения кэша конфигурации', 'VpnService', e);
    }
  }

  /// Сохраняет Xray-конфиг в SecureStorage (полный JSON + client_id, persistent).
  Future<void> _saveXrayConfigToStorage(String config,
      [String? clientId]) async {
    if (_selectedServer == null || !_isXrayProtocol) return;
    try {
      final key =
          'xray_config_${_selectedServer!.id}_${_selectedProtocol.apiValue}';
      final value = clientId != null && clientId.isNotEmpty
          ? jsonEncode({'config': config, 'client_id': clientId})
          : config;
      await _storageService.setSecureString(key, value);
    } catch (e) {
      _logger.error(
          'Ошибка сохранения Xray конфига в SecureStorage', 'VpnService', e);
    }
  }

  /// Очищает кэш конфигурации для текущего сервера и протокола.
  Future<void> _clearConfigCache() async {
    if (_selectedServer == null) return;
    try {
      if (_isXrayProtocol) {
        await _storageService.removeSecureString(
          'xray_config_${_selectedServer!.id}_${_selectedProtocol.apiValue}',
        );
      } else {
        await _cacheService.remove(
            'vpn_config_${_selectedServer!.id}_${_selectedProtocol.name}');
      }
      _logger.debug(
          'Кэш конфигурации очищен для протокола ${_selectedProtocol.name}');
    } catch (e) {
      _logger.error('Ошибка очистки кэша конфигурации', 'VpnService', e);
    }
  }

  /// Публичный метод для сброса кэша Xray-конфига. Вызывать после снятия лимита устройств,
  /// чтобы при следующем подключении запросить свежий конфиг с новым client UUID.
  Future<void> clearXrayConfigCache() async {
    await _clearConfigCache();
  }

  /// COMMIT только после обязательного TCP probe через туннель; счётчик трафика не является критерием успеха.
  Future<bool> _verifyConnection() async {
    final verifyStart = DateTime.now();
    try {
      if (_diagnosticReconnectFromCache && _isXrayProtocol) {
        final connectStart = _diagnosticConnectStartAt ?? verifyStart;
        final elapsedFromConnect =
            verifyStart.difference(connectStart).inMilliseconds;
        _log(
            'VpnService: [DIAG] reconnect-from-cache: verifyConnection вызван, elapsed от connect() до проверки трафика = ${elapsedFromConnect}ms');
        int rx0500 = 0, rx1000 = 0, rx2000 = 0, rx3000 = 0;
        for (final targetMs in [500, 1000, 2000, 3000]) {
          final elapsed =
              DateTime.now().difference(connectStart).inMilliseconds;
          final toWait = targetMs - elapsed;
          if (toWait > 0) await Future.delayed(Duration(milliseconds: toWait));
          try {
            final s = await NativeVpnService.getTrafficStats();
            final rx = ((s['rx_bytes'] ?? 0) as num).toInt();
            final tx = s['tx_bytes'] ?? 0;
            switch (targetMs) {
              case 500:
                rx0500 = rx;
                break;
              case 1000:
                rx1000 = rx;
                break;
              case 2000:
                rx2000 = rx;
                break;
              case 3000:
                rx3000 = rx;
                break;
            }
            _log(
                'VpnService: [DIAG] traffic @ ${targetMs}ms от connect(): rx=$rx, tx=$tx');
          } catch (e) {
            _log('VpnService: [DIAG] traffic @ ${targetMs}ms error: $e');
          }
        }
        final tunnelSlow =
            rx0500 == 0 && rx1000 == 0 && (rx2000 > 0 || rx3000 > 0);
        if (tunnelSlow) {
          _log(
              'VpnService: [DIAG] ВЕРОЯТНО туннель ещё не успел подняться при ранней проверке (трафик появился только после 1с)');
        } else if (rx0500 == 0 && rx1000 == 0 && rx2000 == 0 && rx3000 == 0) {
          _log(
              'VpnService: [DIAG] трафика нет до 3с — туннель возможно не работает');
        }
        _diagnosticReconnectFromCache = false;
      }

      final tcpOk = await _mandatoryTcpThroughTunnelProbe();
      if (!tcpOk) {
        _log('VpnService: ❌ VERIFY: TCP probe не пройден');
        return false;
      }
      _log('VpnService: ✅ VERIFY: TCP probe пройден');
      await _optionalHttpProbeThroughTunnel();
      return true;
    } catch (e) {
      _log('VpnService: ❌ Ошибка проверки подключения: $e');
      return false;
    }
  }

  /// Обязательный TCP через маршрут туннеля (тот же API сокета, что и раньше для REALITY).
  Future<bool> _mandatoryTcpThroughTunnelProbe() async {
    const targets = <(String host, int port, String label)>[
      ('connectivitycheck.gstatic.com', 80, 'gstatic_connectivity_http'),
      ('example.com', 80, 'example_http'),
      ('cloudflare.com', 80, 'cloudflare_http'),
    ];
    for (final t in targets) {
      final ok = await _probeTcpRequest(host: t.$1, port: t.$2);
      if (ok) {
        _log(
            'VpnService: ✅ VERIFY TCP probe target=${t.$3} host=${t.$1}:${t.$2}');
        return true;
      }
      _log(
          'VpnService: ⚠️ VERIFY TCP probe failed target=${t.$3} host=${t.$1}:${t.$2}');
    }
    return false;
  }

  /// Дополнительная уверенность (не заменяет TCP gate).
  Future<void> _optionalHttpProbeThroughTunnel() async {
    try {
      await ControlPlaneClient.instance.execute(
        ControlPlanePlane.vpnControl,
        (dio) => dio
            .get<dynamic>('https://api.ipify.org')
            .timeout(const Duration(seconds: 4)),
      );
    } catch (e) {
      _log('VpnService: ⚠️ OPTIONAL HTTP probe: $e');
    }
  }

  Future<bool> _probeTcpRequest({
    required String host,
    required int port,
  }) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 3),
      );
      socket
          .write('HEAD / HTTP/1.1\r\nHost: $host\r\nConnection: close\r\n\r\n');
      await socket.flush();
      final data = await socket.first.timeout(const Duration(seconds: 3));
      return data.isNotEmpty;
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  /// Определяет, стоит ли повторять подключение при ошибке
  bool _shouldRetry(dynamic error) {
    if (error is TimeoutException && error.message == 'vpn_verify') {
      return true;
    }
    if (error is DioException) {
      return error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.response?.statusCode == 408 ||
          error.response?.statusCode == 500 ||
          error.response?.statusCode == 503 ||
          error.response?.statusCode == 502;
    }
    return false;
  }

  VpnProtocol? _parseProtocolString(String protocolStr) {
    switch (protocolStr) {
      case 'xray_vless':
      case 'vless':
        return VpnProtocol.xrayVless;
      case 'xray_vless_ws_tls':
      case 'vless_ws_tls':
        return VpnProtocol.xrayVlessWsTls;
      case 'xray_vless_grpc_tls':
      case 'vless_grpc_tls':
        return VpnProtocol.xrayVlessGrpcTls;
      case 'xray_vmess':
      case 'vmess':
        return VpnProtocol.xrayVmess;
      case 'xray_reality':
      case 'reality':
        return VpnProtocol.xrayReality;
      case 'graniwg':
        return VpnProtocol.graniwg;
      default:
        return null;
    }
  }

  /// Сохраняет последний успешно использованный сервер и протокол (для отображения после отключения VPN).
  Future<void> _saveLastConnectedSelection() async {
    if (_selectedServer == null) return;
    try {
      await _storageService.setString(
          _keyLastConnectedServerId, _selectedServer!.id);
      await _storageService.setString(
          _keyLastConnectedProtocol, _selectedProtocol.apiValue);
      _log(
          'VpnService: Сохранён последний выбор: server=${_selectedServer!.id}, protocol=${_selectedProtocol.apiValue}');
    } catch (e) {
      _logger.error('Ошибка сохранения последнего выбора', 'VpnService', e);
    }
  }

  /// Сохраняет выбранные в UI сервер и протокол сразу (не ждать успешного connect).
  /// После рестарта процесса [refreshServers] → [_restoreLastConnectedSelection] поднимет тот же протокол.
  Future<void> _persistUserUiSelectionToStorage(
      {required String reason}) async {
    if (_selectedServer == null) {
      _log(
          'VpnService.persist_ui_selection: skip reason=no_server context=$reason');
      return;
    }
    try {
      await _storageService.setString(
          _keyLastConnectedServerId, _selectedServer!.id);
      await _storageService.setString(
          _keyLastConnectedProtocol, _selectedProtocol.apiValue);
      _log(
        'VpnService.persist_ui_selection: reason=$reason server=${_selectedServer!.id} '
        'protocol=${_selectedProtocol.apiValue}',
      );
    } catch (e, st) {
      _logger.error('Ошибка persist_ui_selection', 'VpnService', e, st);
    }
  }

  /// Восстанавливает выбор сервера и протокола из хранилища, если список серверов уже загружен и выбора нет.
  /// Вызывать только когда _servers.isNotEmpty и _selectedServer == null.
  Future<void> _restoreLastConnectedSelection() async {
    if (_servers.isEmpty) return;
    if (_minimalVpnMode) {
      _forceMinimalVpnSelection(reason: 'restore_selection');
      return;
    }
    try {
      final serverId =
          await _storageService.getString(_keyLastConnectedServerId);
      final protocolStr =
          await _storageService.getString(_keyLastConnectedProtocol);
      _log(
        'VpnService.restore_selection: begin stored_server_id=${serverId ?? "-"} '
        'stored_protocol_str=${protocolStr ?? "-"}',
      );
      if (serverId == null || serverId.isEmpty) {
        _log(
            'VpnService.restore_selection: skip source=none reason=no_stored_server');
        return;
      }
      final idx = _servers.indexWhere((s) => s.id == serverId);
      if (idx < 0) {
        _log(
          'VpnService.restore_selection: skip reason=stored_server_not_in_list '
          'stored_server_id=$serverId (список серверов обновился)',
        );
        return;
      }
      final server = _servers[idx];
      _selectedServer = server;
      final parsed =
          protocolStr != null ? _parseProtocolString(protocolStr) : null;
      final supported = server.supportedProtocols;
      final best = _findBestProtocol(server);
      final shouldUpgradePlainVless = parsed == VpnProtocol.xrayVless &&
          best != null &&
          best != parsed &&
          supported != null &&
          supported.contains(best.apiValue);
      if (parsed != null &&
          supported != null &&
          supported.contains(protocolStr) &&
          parsed.isImplemented &&
          !shouldUpgradePlainVless) {
        _selectedProtocol = parsed;
        _log(
          'VpnService.restore_selection: ok source=storage_exact server=${server.id} '
          'protocol=${_selectedProtocol.apiValue} stored_protocol_str=$protocolStr',
        );
      } else {
        if (best != null) _selectedProtocol = best;
        _log(
          'VpnService.restore_selection: ok source=fallback_best server=${server.id} '
          'protocol=${_selectedProtocol.apiValue} stored_protocol_str=${protocolStr ?? "null"} '
          'supported=$supported parsed=${parsed?.apiValue}',
        );
      }
    } catch (e) {
      _logger.error('Ошибка восстановления последнего выбора', 'VpnService', e);
    }
  }

  /// Внутренний метод подключения (без fallback)
  /// Использует _vpnConfig если она уже установлена, иначе получает новую
  Future<bool> _connectInternal(String token) async {
    // Проверяем, поддерживает ли сервер выбранный протокол
    final protocolString = _selectedProtocol.apiValue;

    if (!_minimalVpnMode && _selectedServer!.supportedProtocols != null) {
      if (!_selectedServer!.supportedProtocols!.contains(protocolString)) {
        throw Exception(
            'Сервер не поддерживает протокол ${_selectedProtocol.name}');
      }
    }

    final handler = _handlerFactory?.call(_selectedProtocol) ??
        getHandlerFor(_selectedProtocol);
    if (handler == null) {
      throw Exception('Неподдерживаемый протокол: ${_selectedProtocol.name}');
    }
    if (_vpnConfig != null &&
        _vpnConfig!.isNotEmpty &&
        handler.isConfigValid(_vpnConfig!, _selectedProtocol)) {
      _log(
          'VpnService: Используем уже установленную конфигурацию для протокола ${_selectedProtocol.name}');
      final ok = await handler.applyConfig(_vpnConfig!, _selectedProtocol);
      if (ok) return true;
      _log(
          'VpnService: Не удалось применить существующую конфигурацию, получаем новую');
    } else if (_vpnConfig != null && _vpnConfig!.isNotEmpty) {
      _log(
          'VpnService: Существующая конфигурация невалидна для протокола ${_selectedProtocol.name}, получаем новую');
    }
    _log('VpnService: Начинаем подключение через $protocolString...');
    return await handler.connect(ProtocolConnectParams(
      token: token,
      server: _selectedServer!,
      protocol: _selectedProtocol,
      deviceId: _deviceId,
    ));
  }

  /// Шаг 1 (ConnectOrchestrator): Разрешения, устройство, токен, сервер.
  Future<String> _connectStep1Prerequisites(ConnectAttemptContext ctx) async {
    await _connectStagePermissions(ctx);
    await _connectStageDeviceAndNetwork(ctx);
    final token = await _connectStageTokenAndSync(ctx);
    await _connectStageSelectServerAndLogStart(ctx, token);
    return token;
  }

  /// Шаг 2: Получение конфигурации (кэш или API).
  Future<void> _connectStep2GetConfig(
      ConnectAttemptContext ctx, String token) async {
    await _connectStageGetConfig(ctx, token);
  }

  /// Шаг 3: применение протокола → verify (non-blocking) при уже CONNECTED.
  ///
  /// После успешного native apply сразу фиксируем [VpnConnectionState.connected],
  /// чтобы UI не оставался в бесконечной "крутилке", когда системный VPN уже поднят
  /// (иконка ключа/GRANI в шторке уже видна). Verify остается диагностическим этапом.
  ///
  /// **EXCEPTION (намеренно):** [syncConnectionStateWithNative] и [_restoreConnectionStateFromNative]
  /// могут выставить `connected` без повторного [_connectStageVerify], если нативный VPN
  /// уже работает (плитка / фон / перезапуск приложения). Это не баг: повторный VERIFY здесь
  /// грозит reconnect storm. Не вызывать полный verify в этих путях без RFC и
  /// docs/STAGE_2_NETWORK_CONTRACT.md.
  Future<void> _connectStep3ApplyAndVerify(
      ConnectAttemptContext ctx, String token, int attemptUsed) async {
    _logConnectSessionStage(
      'before_apply_config',
      extra: <String, Object?>{
        'attempt': attemptUsed,
        'protocol': _selectedProtocol.apiValue,
      },
    );
    final result = await _connectStageApplyProtocol(ctx, token);
    _logConnectSessionStage(
      'native_connect_result',
      result: result ? 'ok' : 'failed',
      extra: <String, Object?>{
        'attempt': attemptUsed,
        'protocol': _selectedProtocol.apiValue,
      },
    );
    if (!result) throw Exception('Не удалось установить подключение');
    _logConnectSessionStage(
      'after_apply_config',
      result: 'ok',
      extra: <String, Object?>{
        'attempt': attemptUsed,
      },
    );
    _applyTransition(VpnConnectionState.connected);
    await _connectStageVerify(ctx);
    await _enforceRuntimeContractAgainstEffectiveOutbounds();
    _connectStageOnSuccess(ctx, token, attemptUsed);
    _logConnectSessionStage(
      'commit_result',
      result: 'committed',
      extra: <String, Object?>{
        'attempt': attemptUsed,
      },
    );
  }

  /// Этап 1: проверка разрешений VPN.
  Future<void> _connectStagePermissions(ConnectAttemptContext ctx) async {
    ctx.currentStage = 'permissions';
    _updateProgress(ConnectionProgress.checkingPermissions);
    final hasPermission = await requestVpnPermission();
    if (!hasPermission) {
      throw VpnPermissionException('Необходимо разрешение VPN для подключения');
    }
    _log('VpnService.connect: ✅ Разрешение VPN получено');
    _logConnectionStage(
      stage: 'permissions',
      stopwatch: ctx.stageStopwatch,
      protocol: _selectedProtocol.apiValue,
    );
  }

  /// Этап 2: загрузка device_id (при необходимости), тип сети, MTU.
  Future<void> _connectStageDeviceAndNetwork(ConnectAttemptContext ctx) async {
    if (_deviceId == null) {
      ctx.currentStage = 'load_device_id';
      _log('VpnService.connect: Загружаем device_id (опционально)...');
      await _loadDeviceId();
      if (_deviceId == null) {
        _log(
            'VpnService.connect: device_id недоступен — подключаемся без device_id (один коннект на user+server+protocol)');
      }
    }
    _log('VpnService.connect: device_id = $_deviceId');
    ctx.networkType ??= await _getNetworkTypeLabel();
    _lastNetworkType = ctx.networkType;
    final selectedMtu = _pendingMtuOverride ?? _selectMtu(ctx.networkType);
    _lastMtu = selectedMtu;
    if (_pendingMtuOverride != null) {
      _log(
          'VpnService.connect: используем MTU fallback override=$_pendingMtuOverride '
          '(reason=${_pendingMtuReason ?? "unknown"})');
      _pendingMtuOverride = null;
      _pendingMtuReason = null;
    }
    _log(
        'VpnService.connect: MTU выбран: $_lastMtu (network=${ctx.networkType})');
  }

  /// Этап 3: валидация токена, предзагрузка серверов, sync состояния, credentials логгера.
  Future<String> _connectStageTokenAndSync(ConnectAttemptContext ctx) async {
    ctx.currentStage = 'token_validation';
    _updateProgress(ConnectionProgress.validatingToken);

    await _authService.waitForTokenLoad();
    // Не вызываем ensureValidToken() — ApiClient при 401 сам обновит токен и повторит запрос.
    final token = await _getAuthToken();
    if (token == null || token.isEmpty) {
      throw Exception('Необходима авторизация');
    }

    // До кэша Xray и /vpn/connect: регистрация device_id (лимит — до любого connect).
    ctx.currentStage = 'device_register';
    try {
      await ensureDeviceRegistered(token, verifyQuota: false).timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          _log(
            'VpnService.connect: ensureDeviceRegistered soft-timeout in prerequisites (continue connect)',
          );
        },
      );
    } on DeviceLimitException {
      rethrow;
    } catch (e) {
      _log(
          'VpnService.connect: ensureDeviceRegistered до connect (сеть/прочее, продолжаем): $e');
    }

    // Fast path Xray только после ensureDeviceRegistered — иначе warm-cache обходил лимит.
    if (_diagnosticAllowReconnectFromCache &&
        _isXrayProtocol &&
        _selectedServer != null) {
      try {
        final cached = await _xrayConnectionHandler.getCachedConfig(
            _selectedServer!, _selectedProtocol);
        if (cached != null) {
          _log(
              'VpnService.connect: fast-path (xray cache) после device_register');
          _setConnectionFlowType(ConnectionFlowType.warmCacheReconnect);
          return token;
        }
      } catch (_) {
        // Если кэш недоступен/битый — идём по обычному пути.
      }
    }

    _log('VpnService.connect: ✅ Токен загружен (длина: ${token.length})');
    if (_servers.isEmpty) {
      _log('VpnService.connect: Предзагрузка списка серверов...');
      await refreshServers();
    }
    _logConnectionStage(
      stage: 'token_validation',
      stopwatch: ctx.stageStopwatch,
      protocol: _selectedProtocol.apiValue,
      networkType: ctx.networkType,
    );
    if (_deviceId != null) {
      _connectionLogger.setCredentials(token, _deviceId!,
          flushImmediately: false);
    }

    ctx.currentStage = 'sync_state';
    if (_skipSyncConnectionStateOnConnect) {
      _log(
          'VpnService.connect: Пропуск sync (временно отключен для упрощения connect/disconnect)');
    } else if (!_connectionStateSyncDoneThisSession) {
      _log(
          'VpnService.connect: Синхронизация состояния в фоне (не блокируем подключение)');
      _connectionStateSyncDoneThisSession = true;
      unawaited(_syncConnectionState().then((_) {
        _log('VpnService.connect: ✅ Sync состояния завершён в фоне');
      }).catchError((Object e) {
        _log('VpnService.connect: Sync в фоне (игнор): $e');
      }));
    } else {
      _log('VpnService.connect: Пропуск sync (уже выполнялась в этой сессии)');
    }
    _logConnectionStage(
      stage: 'sync_state',
      stopwatch: ctx.stageStopwatch,
      protocol: _selectedProtocol.apiValue,
      networkType: ctx.networkType,
    );
    return token;
  }

  /// Этап 4: выбор сервера/протокола, логирование начала подключения.
  Future<void> _connectStageSelectServerAndLogStart(
      ConnectAttemptContext ctx, String token) async {
    ctx.currentStage = 'select_server';
    await _autoSelectServerAndProtocol();
    if (_selectedServer == null) throw Exception('Не удалось выбрать сервер');
    _log(
        'VpnService.connect: ✅ Сервер выбран: ${_selectedServer!.id}, протокол: ${_selectedProtocol.name}');
    _logConnectionStage(
      stage: 'select_server',
      stopwatch: ctx.stageStopwatch,
      protocol: _selectedProtocol.apiValue,
      networkType: ctx.networkType,
    );
    if (_deviceId != null) {
      _connectionLogger.logConnectionStart(
        deviceId: _deviceId!,
        protocol: _selectedProtocol.apiValue,
        clientId: _clientId,
        serverId: int.tryParse(_selectedServer!.id),
        networkType: ctx.networkType,
        connectionSessionId: _connectionSessionId,
        trigger: _connectionTrigger,
        connectionFlowType: _connectionFlowType.name,
      );
    }
  }

  /// Проверяет ответ 400 от /vpn/connect: при DEVICE_LIMIT_EXCEEDED выбрасывает [DeviceLimitException].
  void _throwIfDeviceLimitFrom400(dynamic errorData) {
    if (errorData is! Map || errorData['error'] is! Map) return;
    final err = errorData['error'] as Map;
    if (err['code'] != 'DEVICE_LIMIT_EXCEEDED') return;
    final message =
        err['message'] as String? ?? 'Достигнут лимит устройств (5)';
    final details = err['details'] is Map ? err['details'] as Map : null;
    final limit = details != null ? details['limit'] as int? : null;
    final currentCount =
        details != null ? details['current_count'] as int? : null;
    final devices = details != null && details['devices'] is List
        ? details['devices'] as List
        : <dynamic>[];
    throw DeviceLimitException(message,
        limit: limit, currentCount: currentCount, devices: devices);
  }

  static bool _isAlreadyConnected400Message(String? message) {
    if (message == null) return false;
    final lower = message.toLowerCase();
    return lower.contains('уже подключено') ||
        lower.contains('already connected');
  }

  /// После 400 «уже подключено»: отключаем на сервере, синхронизируем состояние, повторно запрашиваем конфиг.
  Future<Response> _fetchConfigAfterAlreadyConnected(
      String token, String protocolString) async {
    _log(
        'VpnService.connect: ⚠️ Устройство уже подключено на сервере, отключаем...');
    final disconnectSuccess = await _forceDisconnectOnServer(token);
    if (disconnectSuccess) {
      await Future.delayed(const Duration(milliseconds: 300));
      await _syncConnectionState(force: true);
    } else {
      await Future.delayed(const Duration(milliseconds: 600));
    }
    return _apiClient.post(
      '/vpn/connect',
      data: await _connectPayload(protocolString),
      options: await _vpnApiOptions({'Authorization': 'Bearer $token'}),
    );
  }

  Future<Response<dynamic>> _fetchSimpleVpnConfig(String token) async {
    return _apiClient.get(
      '/simple-vpn/config',
      queryParameters: <String, dynamic>{
        if (_deviceId != null && _deviceId!.isNotEmpty) 'device_id': _deviceId,
        if (_selectedServer != null)
          'server_id': int.tryParse(_selectedServer!.id),
      },
      options: await _vpnApiOptions({'Authorization': 'Bearer $token'}),
    );
  }

  /// Этап 5: получение конфигурации (кэш или API), установка _vpnConfig.
  Future<void> _connectStageGetConfig(
      ConnectAttemptContext ctx, String token) async {
    final protocolString = _selectedProtocol.apiValue;
    final isXrayProtocol = _isXrayProtocol;

    ctx.currentStage = 'get_config';
    _updateProgress(ConnectionProgress.gettingConfig);

    String? config = await _getCachedConfig();

    if (_isGraniWgProtocol) {
      _setConnectionFlowType(ConnectionFlowType.coldCreateConfig);
      final response = await _fetchSimpleVpnConfig(token);
      if (response.statusCode == 200 && response.data['success'] == true) {
        final rawConfig = response.data['config'];
        config = rawConfig == null
            ? null
            : (rawConfig is String ? rawConfig : jsonEncode(rawConfig));
        final jsonConfig = response.data['json_config'];
        if (jsonConfig is Map && jsonConfig['vpn_ip'] != null) {
          _currentIpAddress = jsonConfig['vpn_ip'].toString();
        }
        if (config != null) await _cacheConfig(config);
        _log(
          'VpnService.connect: ✅ AmneziaWG config получен через simple-vpn (длина: ${config?.length})',
        );
      } else {
        throw Exception(response.data['detail'] ??
            'Ошибка получения AmneziaWG конфигурации');
      }
    }
    // Xray: не используем кэш конфига на этапе get_config — конфиг получаем в _connectXray()
    // (GET /config по client_id или create-client), чтобы всегда иметь актуальный client_id.
    if (isXrayProtocol) config = null;

    if (config == null && !isXrayProtocol && !_isGraniWgProtocol) {
      _setConnectionFlowType(ConnectionFlowType.coldCreateConfig);
      Response response;
      try {
        final connectData = <String, dynamic>{
          'server_id': int.parse(_selectedServer!.id),
          'protocol': protocolString,
        };
        if (_deviceId != null && _deviceId!.isNotEmpty) {
          connectData['device_id'] = _deviceId;
        }
        response = await _apiClient.post(
          '/vpn/connect',
          data: connectData,
          options: await _vpnApiOptions({'Authorization': 'Bearer $token'}),
        );
      } on DioException catch (e) {
        if (e.response?.statusCode == 400) {
          final errorData = e.response?.data;
          _throwIfDeviceLimitFrom400(errorData);
          String? errorMessage;
          if (errorData is Map) {
            errorMessage = (errorData['error'] is Map
                ? errorData['error']['message']
                : errorData['message']) as String?;
          }
          if (_isAlreadyConnected400Message(errorMessage)) {
            response =
                await _fetchConfigAfterAlreadyConnected(token, protocolString);
          } else {
            rethrow;
          }
        } else {
          rethrow;
        }
      }

      if (response.statusCode == 200 && response.data['success'] == true) {
        final rawConfig = response.data['config'];
        config = rawConfig == null
            ? null
            : (rawConfig is String ? rawConfig : jsonEncode(rawConfig));
        _currentIpAddress = response.data['ip_address'];
        if (config != null) await _cacheConfig(config);
        _log(
            'VpnService.connect: ✅ Конфигурация получена (длина: ${config?.length})');
      } else {
        throw Exception(
            response.data['detail'] ?? 'Ошибка получения конфигурации');
      }
    } else if (config != null && !_isGraniWgProtocol) {
      _setConnectionFlowType(ConnectionFlowType.warmCacheReconnect);
      _log('VpnService.connect: ✅ Конфигурация загружена из кэша');
    } else if (isXrayProtocol) {
      if (_connectionFlowType == ConnectionFlowType.unknown) {
        _setConnectionFlowType(ConnectionFlowType.coldCreateConfig);
      }
      _log(
          'VpnService.connect: XRay протокол - конфигурация будет получена в _connectXray()');
    }

    if (config != null && config.isNotEmpty) {
      _vpnConfig = config;
      _log(
          'VpnService.connect: ✅ Конфигурация сохранена в _vpnConfig (длина: ${_vpnConfig!.length})');
    } else if (isXrayProtocol) {
      _vpnConfig = null;
    } else {
      throw Exception('Конфигурация не получена или пуста');
    }
    _logConnectionStage(
      stage: 'get_config',
      stopwatch: ctx.stageStopwatch,
      protocol: _selectedProtocol.apiValue,
      networkType: ctx.networkType,
      apiRouteUsed: PreferredRouteStorage.lastSuccessfulRouteForLogging,
      apiRequestMs: _apiClient is ApiClient ? ApiClient.lastRequestMs : null,
    );
    _logConnectSessionStage(
      'after_fetch_config',
      result: 'ok',
      extra: <String, Object?>{
        'protocol': _selectedProtocol.apiValue,
        'has_config': _vpnConfig != null,
        'config_len': _vpnConfig?.length ?? 0,
      },
    );
  }

  /// Этап 6: применение протокола (WireGuard/Xray/…) без автопереключения протокола.
  Future<bool> _connectStageApplyProtocol(
      ConnectAttemptContext ctx, String token) async {
    ctx.currentStage = 'parse_config';
    _updateProgress(ConnectionProgress.parsingConfig);
    ctx.currentStage = 'apply_protocol';
    _updateProgress(ConnectionProgress.creatingTun);
    _updateProgress(ConnectionProgress.startingProtocol);

    bool result;
    try {
      if (_selectedProtocol.isImplemented) {
        result = await _connectInternal(token);
      } else {
        throw Exception('Неподдерживаемый протокол: ${_selectedProtocol.name}');
      }
    } catch (e) {
      rethrow;
    }

    _logConnectionStage(
      stage: 'apply_protocol',
      stopwatch: ctx.stageStopwatch,
      protocol: _selectedProtocol.apiValue,
      networkType: ctx.networkType,
      apiRouteUsed: PreferredRouteStorage.lastSuccessfulRouteForLogging,
      apiRequestMs: _apiClient is ApiClient ? ApiClient.lastRequestMs : null,
    );
    final getConfigMs = _lastConnectionTimingMs['get_config'];
    final applyProtocolMs = _lastConnectionTimingMs['apply_protocol'];
    if (getConfigMs != null &&
        applyProtocolMs != null &&
        applyProtocolMs >= getConfigMs) {
      _lastConnectionTimingMs['engine_init_ms'] = applyProtocolMs - getConfigMs;
    }
    return result;
  }

  /// Этап 7: верификация (диагностическая, НЕ блокирующая connect).
  /// Временный режим для полевых тестов: даже при timeout/failed verify
  /// подключение не рвём и не переводим в ошибку.
  Future<bool> _connectStageVerify(ConnectAttemptContext ctx) async {
    _scheduleApplyAckBackgroundCheck();
    if (_currentState != VpnConnectionState.connected) {
      _applyTransition(VpnConnectionState.tunnelVerifying);
    }
    ctx.currentStage = 'verify_connection';
    _updateProgress(ConnectionProgress.verifyingConnection);
    bool verificationResult = false;
    try {
      verificationResult = await _verifyConnection().timeout(
        TunnelVerifyCriteria.productionDefaults.maxVerifyWallClock,
      );
    } on TimeoutException catch (_) {
      _log(
          'VpnService.connect: ⚠️ VERIFY timeout — пропускаем (non-blocking test mode)');
      verificationResult = false;
    }
    _logConnectionStage(
      stage: 'verify_connection',
      stopwatch: ctx.stageStopwatch,
      protocol: _selectedProtocol.apiValue,
      networkType: ctx.networkType,
    );

    if (!verificationResult) {
      _log(
          'VpnService.connect: ⚠️ VERIFY failed — пропускаем (non-blocking test mode)');
      return true;
    }
    return true;
  }

  void _scheduleApplyAckBackgroundCheck() {
    if (_minimalVpnMode) {
      _log('VpnService.minimal_mode: apply-ack background check disabled');
      return;
    }
    if (!_isXrayProtocol || _selectedServer == null) return;
    final revision = (_pendingApplyConfigRevision ?? '').trim();
    if (revision.isEmpty || _applyAckBackgroundInFlight) return;
    _applyAckBackgroundInFlight = true;
    _connectedWithAckDelay = false;
    _logConnectSessionStage(
      'apply_ack_background_start',
      extra: <String, Object?>{
        'revision': revision,
      },
    );
    unawaited(() async {
      try {
        await _waitForXrayApplyAckIfNeeded();
        _connectedWithAckDelay = false;
        _pendingApplyConfigRevision = null;
        _pendingApplyPhase = null;
        _logConnectSessionStage(
          'apply_ack_background_result',
          result: 'applied',
        );
      } catch (e) {
        _connectedWithAckDelay = true;
        _lastConnectionErrorMessage = null;
        _log(
          'VpnService: apply-ack delayed (soft) — keep connected: $e',
        );
        _logConnectSessionStage(
          'connected_with_ack_delay',
          result: 'soft_warning',
          extra: <String, Object?>{
            'error_type': e.runtimeType.toString(),
            'state': _currentState.name,
          },
        );
      } finally {
        _applyAckBackgroundInFlight = false;
        notifyListeners();
      }
    }());
  }

  bool _isApplyAckTransportRetryable(DioException e) {
    if (e.response != null) return false;
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.connectionError) {
      return true;
    }
    if (e.type == DioExceptionType.unknown) {
      final text = '${e.message ?? ""} ${e.error ?? ""}'.toLowerCase();
      return text.contains('connection reset') ||
          text.contains('connection aborted') ||
          text.contains('broken pipe') ||
          text.contains('socketexception');
    }
    return false;
  }

  Future<void> _waitForXrayApplyAckIfNeeded() async {
    if (!_isXrayProtocol || _selectedServer == null) return;
    final token = await _getAuthToken();
    if (token == null || token.isEmpty) return;
    final revision = (_pendingApplyConfigRevision ?? '').trim();
    if (revision.isEmpty) {
      _log('VpnService: apply-ack skip (no revision)');
      return;
    }
    final serverId = int.tryParse(_selectedServer!.id);
    if (serverId == null) return;

    final options = await _vpnApiOptions(
      {'Authorization': 'Bearer $token'},
      readHeavy: true,
    );
    final extra = <String, dynamic>{...(options.extra ?? const {})};
    extra['grani_skip_api_gate'] = true;
    final start = DateTime.now().millisecondsSinceEpoch;
    _log(
      'VpnService: apply-ack wait start server_id=$serverId revision=$revision '
      'session=${_connectionSessionId ?? "-"}',
    );

    var boundUnderlying = false;
    if (Platform.isAndroid) {
      try {
        boundUnderlying =
            await NativeVpnService.bindUnderlyingNetworkForControlPlane();
        if (boundUnderlying) {
          _log('VpnService: apply-ack Android bind=underlying(NOT_VPN)');
        }
      } catch (e) {
        _log('VpnService: apply-ack bind underlying ignored: $e');
      }
    }

    Future<Response<dynamic>> fetchApplyState(int timeoutSec) {
      return _apiClient.get(
        '/vpn/xray/apply-state',
        queryParameters: {
          'server_id': serverId,
          'config_revision': revision,
          'wait_for': 'applied',
          'timeout_sec': timeoutSec,
        },
        // Long-poll (timeout_sec>0): новый TCP без keep-alive — меньше RST на длинном удержании.
        // Snapshot (timeout_sec==0): keep-alive — быстрый первый RTT к Nginx upstream pool.
        options: options.copyWith(
          extra: extra,
          persistentConnection: timeoutSec == 0,
        ),
      );
    }

    bool applyStateBodyShowsApplied(Map<String, dynamic> data) {
      return data['is_applied'] == true;
    }

    void logApplyStateOutcome(
      Map<String, dynamic> data, {
      required String phase,
      required int elapsedMs,
    }) {
      final status = (data['status'] ?? '').toString();
      final isApplied = data['is_applied'] == true;
      final timedOut = data['timed_out'] == true;
      final waitedMs = data['waited_ms'];
      _log(
        'VpnService: apply-ack $phase status=$status is_applied=$isApplied '
        'timed_out=$timedOut waited_ms=${waitedMs ?? "-"} elapsed_ms=$elapsedMs',
      );
    }

    const maxAckWindow = Duration(seconds: 28);
    const retryPlanSeconds = <int>[1, 2, 4, 8];
    int jitterMs() => Random().nextInt(351);
    try {
      var useClientPollOnly = false;
      var attempt = 0;
      while (true) {
        final elapsedNowMs = DateTime.now().millisecondsSinceEpoch - start;
        if (elapsedNowMs >= maxAckWindow.inMilliseconds) {
          throw Exception(
            'Конфигурация VPN еще применяется на сервере (ACK timeout window=${maxAckWindow.inSeconds}s).',
          );
        }
        if (attempt > 0) {
          final retryIdx = attempt - 1;
          final baseSec = retryIdx < retryPlanSeconds.length
              ? retryPlanSeconds[retryIdx]
              : retryPlanSeconds.last;
          var backoffMs = baseSec * 1000 + jitterMs();
          final remainingMs = maxAckWindow.inMilliseconds - elapsedNowMs;
          if (backoffMs > remainingMs) {
            backoffMs = remainingMs;
          }
          if (backoffMs <= 0) {
            throw Exception(
              'Конфигурация VPN еще применяется на сервере (ACK timeout window=${maxAckWindow.inSeconds}s).',
            );
          }
          _log(
            'VpnService: apply-ack retry attempt=$attempt '
            'backoff_ms=$backoffMs plan_s=$baseSec jitter=true',
          );
          await Future<void>.delayed(Duration(milliseconds: backoffMs));
        }
        try {
          if (useClientPollOnly) {
            const pollSeconds = 15;
            for (var s = 0; s < pollSeconds; s++) {
              final resp = await fetchApplyState(0);
              final data = resp.data is Map<String, dynamic>
                  ? resp.data as Map<String, dynamic>
                  : <String, dynamic>{};
              final elapsedMs = DateTime.now().millisecondsSinceEpoch - start;
              logApplyStateOutcome(data, phase: 'poll0', elapsedMs: elapsedMs);
              if (applyStateBodyShowsApplied(data)) {
                return;
              }
              await Future<void>.delayed(const Duration(seconds: 1));
            }
            throw Exception(
              'Конфигурация VPN еще применяется на сервере (ACK timeout). Повторите подключение через пару секунд.',
            );
          }

          // Сначала короткий снимок (timeout_sec=0): один быстрый RTT, apply часто уже готов.
          final snap = await fetchApplyState(0);
          final snapData = snap.data is Map<String, dynamic>
              ? snap.data as Map<String, dynamic>
              : <String, dynamic>{};
          logApplyStateOutcome(
            snapData,
            phase: 'snapshot',
            elapsedMs: DateTime.now().millisecondsSinceEpoch - start,
          );
          if (applyStateBodyShowsApplied(snapData)) {
            return;
          }

          final resp = await fetchApplyState(15);
          final data = resp.data is Map<String, dynamic>
              ? resp.data as Map<String, dynamic>
              : <String, dynamic>{};
          final elapsedMs = DateTime.now().millisecondsSinceEpoch - start;
          logApplyStateOutcome(data, phase: 'longpoll', elapsedMs: elapsedMs);

          if (!applyStateBodyShowsApplied(data)) {
            final timedOut = data['timed_out'] == true;
            if (timedOut) {
              throw Exception(
                'Конфигурация VPN еще применяется на сервере (ACK timeout). Повторите подключение через пару секунд.',
              );
            }
            throw Exception(
              'Конфигурация VPN не применена на сервере (status=${(data['status'] ?? '').toString()}).',
            );
          }
          return;
        } on DioException catch (e) {
          if (_isApplyAckTransportRetryable(e)) {
            useClientPollOnly = true;
          }
          if (!_isApplyAckTransportRetryable(e)) {
            rethrow;
          }
          _log(
              'VpnService: apply-ack transport error (will retry): ${e.message}');
        }
        attempt += 1;
      }
    } finally {
      if (boundUnderlying) {
        try {
          await NativeVpnService.unbindUnderlyingNetworkForControlPlane();
          _log('VpnService: apply-ack Android bind cleared');
        } catch (e) {
          _log('VpnService: apply-ack unbind ignored: $e');
        }
      }
    }
  }

  /// Этап 8: финализация успеха — переход в connected, мониторинг, логирование.
  void _connectStageOnSuccess(
      ConnectAttemptContext ctx, String token, int attemptUsed) {
    AppConfig.vpnTunnelConnectedAt = DateTime.now();
    _updateProgress(ConnectionProgress.connected);
    _applyTransition(VpnConnectionState.connected);
    if (_connectStartTrialTimer) _connectionStartTime = DateTime.now();
    _startTrafficStatsMonitoring();
    _reconnectionAttempts = 0;
    _saveLastConnectedSelection();
    _startPostConnectCommitWatch();
    notifyListeners();
    _log(
      'VpnService.connect: локальный туннель поднят, ждём connectivity commit',
    );

    if (_deviceId != null) {
      String? effectiveOutbounds;
      if (Platform.isAndroid) {
        effectiveOutbounds = _cachedEffectiveOutbounds;
        if (effectiveOutbounds == null || effectiveOutbounds.isEmpty) {
          unawaited(() async {
            final fetched = await NativeVpnService.getEffectiveOutbounds();
            if (fetched != null && fetched.isNotEmpty) {
              _cachedEffectiveOutbounds = fetched;
            }
          }());
        }
      }
      // Stage-level success: local tunnel up.
      _connectionLogger.logConnectionStage(
        deviceId: _deviceId!,
        protocol: _selectedProtocol.apiValue,
        stage: 'connected_local',
        clientId: _clientId,
        serverId: int.tryParse(_selectedServer!.id),
        connectionSessionId: _connectionSessionId,
        trigger: _connectionTrigger,
        extraDetails:
            effectiveOutbounds != null && effectiveOutbounds.isNotEmpty
                ? <String, dynamic>{'effective_outbounds': effectiveOutbounds}
                : null,
      );
    }
    _connectionLogger.scheduleFlush();
    unawaited(_runAppConflictBProxyOnlyProbe());

    final tapToConnectedMs = ctx.connectionStopwatch.elapsedMilliseconds;
    _lastConnectionTimingMs['tap_to_connected_ms'] = tapToConnectedMs;
    _logConnectionTimingSummary(tapToConnectedMs, result: 'success');
    _logConnectSessionStage(
      'connected_local',
      result: 'ok',
      extra: <String, Object?>{
        'attempt': attemptUsed,
        'trigger': _connectionTrigger,
      },
    );
  }

  Future<void> _runAppConflictBProxyOnlyProbe() async {
    if (!Platform.isAndroid || !_isXrayProtocol || _deviceId == null) return;
    const marker = 'app_conflict_b_proxy_only_probe_v1_2026_05_12';
    final protocol = _selectedProtocol.apiValue;
    final serverId = int.tryParse(_selectedServer?.id ?? '');
    final sessionId = _connectionSessionId;
    final targets = <String>[
      'https://www.gstatic.com/generate_204',
      'https://www.youtube.com/generate_204',
    ];

    void logStage(String stage, Map<String, dynamic> details) {
      _connectionLogger.logConnectionStage(
        deviceId: _deviceId!,
        protocol: protocol,
        stage: stage,
        clientId: _clientId,
        serverId: serverId,
        connectionSessionId: sessionId,
        trigger: _connectionTrigger,
        extraDetails: <String, dynamic>{
          'marker': marker,
          'transport': 'local_xray_socks_127.0.0.1_10808',
          'bypasses_tun2socks': true,
          ...details,
        },
      );
    }

    logStage('app_conflict_b_proxy_probe_start', <String, dynamic>{
      'targets': targets,
    });
    _connectionLogger.scheduleFlush();

    for (final target in targets) {
      final sw = Stopwatch()..start();
      try {
        final response = await NativeVpnService.apiRequestViaLocalSocks(
          url: target,
          method: 'GET',
          headers: const <String, String>{
            'User-Agent': 'GRANI-AppConflictB/1.0',
            'Cache-Control': 'no-cache',
          },
        ).timeout(const Duration(seconds: 35));
        sw.stop();
        final status = response['statusCode'];
        final body = response['body'];
        logStage('app_conflict_b_proxy_probe_result', <String, dynamic>{
          'target': target,
          'ok': status is int && status >= 200 && status < 500,
          'status_code': status,
          'elapsed_ms': sw.elapsedMilliseconds,
          'body_len': body is String ? body.length : -1,
        });
        await _connectionLogger.flushDiagnosticsOnConnectFail();
        return;
      } catch (e) {
        sw.stop();
        logStage('app_conflict_b_proxy_probe_error', <String, dynamic>{
          'target': target,
          'ok': false,
          'elapsed_ms': sw.elapsedMilliseconds,
          'error_type': e.runtimeType.toString(),
          'error': e.toString(),
        });
        await _connectionLogger.flushDiagnosticsOnConnectFail();
      }
    }
  }

  void _prepareConnectPreflight({required bool startTrialTimer}) {
    _ConnectStateHelpers.prepareConnectPreflight(this,
        startTrialTimer: startTrialTimer);
  }

  Future<bool> _syncConnectedFromNativePrecheck() async {
    return _ConnectStateHelpers.syncConnectedFromNativePrecheck(this);
  }

  Future<void> _awaitBootstrapForConnect() async {
    await _ConnectStateHelpers.awaitBootstrapForConnect(this);
  }

  Future<void> _prepareConnectStageExecution() async {
    await _ConnectStateHelpers.prepareConnectStageExecution(this);
  }

  void _handleConnectAttemptTimeout(Object error) {
    _ConnectStateHelpers.handleConnectAttemptTimeout(this, error);
  }

  void _logConnectAttemptErrorTelemetry(
    Object error,
    StackTrace stackTrace,
    ConnectAttemptContext? ctx,
    String protocolString,
  ) {
    _ConnectStateHelpers.logConnectAttemptErrorTelemetry(
      this,
      error,
      stackTrace,
      ctx,
      protocolString,
    );
  }

  void _applyConnectFailureState({
    required Object error,
    required int connectionDurationMs,
    required PerfLogger perfLogger,
    required int attemptUsed,
    required String protocolString,
    String? stage,
    bool rethrowError = false,
  }) {
    _ConnectStateHelpers.applyConnectFailureState(
      this,
      error: error,
      connectionDurationMs: connectionDurationMs,
      perfLogger: perfLogger,
      attemptUsed: attemptUsed,
      protocolString: protocolString,
      stage: stage,
      rethrowError: rethrowError,
    );
  }

  void _logDioConnectError(DioException error) {
    _ConnectStateHelpers.logDioConnectError(this, error);
  }

  void _notifyListenersFromHelper() {
    notifyListeners();
  }

  Future<bool> _runConnectAttempts() async {
    return _ConnectAttemptExecutor(this).run();
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

  Future<bool> _connectXray(String token) async {
    final totalSw = Stopwatch()..start();
    final sessionId = _connectionSessionId;
    void ensureActiveSession(String stage) {
      if (!_isConnectionSessionActive(sessionId)) {
        _log(
          'VpnService._connectXray: stale session detected stage=$stage '
          'active=${_connectionSessionId ?? "null"} current=${sessionId ?? "null"}',
        );
        throw StaleConnectSessionException(stage);
      }
    }

    try {
      if (defaultTargetPlatform != TargetPlatform.android) {
        const message = 'Xray доступен только на Android устройствах.';
        _setError(message);
        notifyListeners();
        throw Exception(message);
      }
      if (!_xrayAvailable) {
        await _refreshXrayAvailability();
        if (!_xrayAvailable) {
          const message =
              'Xray недоступен на этом устройстве. Проверьте сборку приложения.';
          _setError(message);
          notifyListeners();
          throw Exception(message);
        }
      }
      _log('VpnService._connectXray: Начало подключения Xray');
      _log(
          'VpnService._connectXray: server_id = ${_selectedServer!.id}, device_id = $_deviceId');
      _log('VpnService._connectXray: protocol = ${_selectedProtocol.apiValue}');
      _logXrayTiming('xray_connect_start', {
        'server_id': _selectedServer!.id,
        'protocol': _selectedProtocol.apiValue,
        'device_id_present':
            _deviceId != null && (_deviceId?.isNotEmpty ?? false),
        'trigger': _connectionTrigger ?? 'unknown',
      });

      final handler = _xrayConnectionHandler;

      // При reconnect (тот же сервер/протокол) берём конфиг из хранилища — без API.
      final cached = _diagnosticAllowReconnectFromCache
          ? await handler.getCachedConfig(_selectedServer!, _selectedProtocol)
          : null;
      if (cached != null) {
        final cacheApplySw = Stopwatch()..start();
        ensureActiveSession('cache_before_apply');
        _diagnosticReconnectFromCache = true;
        _log(
            'VpnService._connectXray: [DIAG] используем конфиг из кэша (reconnect без API)');
        if (_deviceId != null) {
          _connectionLogger.logConnectionStage(
            deviceId: _deviceId!,
            protocol: _selectedProtocol.apiValue,
            stage: 'reconnect_from_cache',
            durationMs: 0,
            clientId: cached.clientId,
            serverId: _selectedServer != null
                ? int.tryParse(_selectedServer!.id)
                : null,
            connectionSessionId: _connectionSessionId,
            trigger: 'reconnect_from_cache',
          );
        }
        _clientId = cached.clientId;
        _currentIpAddress = null;
        _vpnConfig = cached.jsonConfig;
        _pendingApplyConfigRevision =
            cached.applyConfigRevision ?? cached.serverConfigRevision;
        _pendingApplyPhase = cached.applyPhase;
        _lastRuntimeContract = cached.runtimeContract;
        _lastRuntimeCorrelationId = cached.correlationId;
        try {
          _logXrayTiming('xray_cache_hit', {
            'elapsed_ms': totalSw.elapsedMilliseconds,
            'server_id': _selectedServer!.id,
            'protocol': _selectedProtocol.apiValue,
          });
          final result = await handler.applyConfig(
            configJson: cached.jsonConfig,
            protocol: _selectedProtocol,
            mtu: _lastMtu ?? _selectMtu(_lastNetworkType),
            connectionSessionId: sessionId,
            nativeSource: _connectionTrigger,
            runtimeContract: cached.runtimeContract,
            correlationId: cached.correlationId,
            onConnectStateChanged: _onNativeVpnLinkChanged,
          );
          ensureActiveSession('cache_after_apply');
          if (result.success && result.xrayProtocol != null) {
            final applyMs = cacheApplySw.elapsedMilliseconds;
            _lastConnectionTimingMs['xray_apply_from_cache_ms'] = applyMs;
            _lastConnectionTimingMs['xray_total_ms'] =
                totalSw.elapsedMilliseconds;
            _logXrayTiming('xray_connected_from_cache', {
              'apply_ms': applyMs,
              'total_ms': totalSw.elapsedMilliseconds,
              'server_id': _selectedServer!.id,
              'protocol': _selectedProtocol.apiValue,
            });
            _xrayProtocol = result.xrayProtocol;
            _lastTunnelConnectedAt = DateTime.now();
            _startTrafficStatsMonitoring();
            _startNetworkChangeListener();
            _reconnectionAttempts = 0;
            notifyListeners();
            _log(
                'VpnService._connectXray: Xray подключение успешно установлено из кэша');
            return true;
          }
        } catch (e) {
          if (e is VpnPermissionException) rethrow;
          _log(
              'VpnService._connectXray: Кеш невалиден, сбрасываем и запрашиваем свежий конфиг: $e');
          _logXrayTiming('xray_cache_apply_failed', {
            'elapsed_ms': totalSw.elapsedMilliseconds,
            'error': e.runtimeType,
          });
        }
        _vpnConfig = null;
        _clientId = null;
        await _clearConfigCache();
        _log(
            'VpnService._connectXray: Кеш сброшен, переходим к получению конфига с API');
      }

      final fetchSw = Stopwatch()..start();
      _logXrayTiming('xray_fetch_config_start', {
        'elapsed_ms': totalSw.elapsedMilliseconds,
        'server_id': _selectedServer!.id,
        'protocol': _selectedProtocol.apiValue,
      });
      final data = await handler.fetchConfig(
        token: token,
        server: _selectedServer!,
        protocol: _selectedProtocol,
        deviceId: _deviceId,
        connectionSessionId: sessionId,
        forceFresh: true,
        useSessionPrepare: false,
      );
      ensureActiveSession('after_fetch_config');
      final fetchMs = fetchSw.elapsedMilliseconds;
      _lastConnectionTimingMs['xray_fetch_config_ms'] = fetchMs;
      _logXrayTiming('xray_fetch_config_done', {
        'fetch_ms': fetchMs,
        'elapsed_ms': totalSw.elapsedMilliseconds,
        'server_id': _selectedServer!.id,
        'protocol': _selectedProtocol.apiValue,
        'client_id_present':
            data.clientId != null && (data.clientId?.isNotEmpty ?? false),
      });
      _logConnectSessionStage(
        'after_fetch_config',
        result: 'ok',
        extra: <String, Object?>{
          'protocol': _selectedProtocol.apiValue,
          'request_id': data.requestId ?? '-',
          'correlation_id': data.correlationId ?? '-',
          'session': _connectionSessionId ?? '-',
          'config_len': data.jsonConfig.length,
        },
      );
      _clientId = data.clientId;
      _currentIpAddress = data.ipAddress;
      _vpnConfig = data.jsonConfig;
      _pendingApplyConfigRevision =
          data.applyConfigRevision ?? data.serverConfigRevision;
      _pendingApplyPhase = data.applyPhase;
      _lastRuntimeContract = data.runtimeContract;
      _lastRuntimeCorrelationId = data.correlationId;
      await _cacheConfig(_vpnConfig!, _clientId);

      // Если backend вернул queued/applying, не поднимаем туннель до ACK apply-state.
      if (!_minimalVpnMode &&
          (_pendingApplyPhase ?? '').toLowerCase() ==
              'await_apply_confirmation') {
        _log(
          'VpnService._connectXray: backend phase=await_apply_confirmation, '
          'ждем apply ACK до native connect '
          'retry_after=${data.retryAfterSec ?? 2}s',
        );
        await _waitForXrayApplyAckIfNeeded();
        ensureActiveSession('after_pre_apply_ack');
      } else if (_minimalVpnMode &&
          (_pendingApplyPhase ?? '').toLowerCase() ==
              'await_apply_confirmation') {
        _log(
            'VpnService.minimal_mode: skip blocking apply ACK before native connect');
      }

      final applySw = Stopwatch()..start();
      _logXrayTiming('xray_apply_config_start', {
        'elapsed_ms': totalSw.elapsedMilliseconds,
        'server_id': _selectedServer!.id,
        'protocol': _selectedProtocol.apiValue,
        'mtu': _lastMtu ?? _selectMtu(_lastNetworkType),
      });
      final result = await handler.applyConfig(
        configJson: data.jsonConfig,
        protocol: _selectedProtocol,
        mtu: _lastMtu ?? _selectMtu(_lastNetworkType),
        connectionSessionId: sessionId,
        nativeSource: _connectionTrigger,
        runtimeContract: data.runtimeContract,
        correlationId: data.correlationId,
        onConnectStateChanged: _onNativeVpnLinkChanged,
      );
      ensureActiveSession('after_apply_config');
      if (result.success && result.xrayProtocol != null) {
        final applyMs = applySw.elapsedMilliseconds;
        _lastConnectionTimingMs['xray_apply_config_ms'] = applyMs;
        _lastConnectionTimingMs['xray_total_ms'] = totalSw.elapsedMilliseconds;
        _logXrayTiming('xray_connected', {
          'fetch_ms': fetchMs,
          'apply_ms': applyMs,
          'total_ms': totalSw.elapsedMilliseconds,
          'server_id': _selectedServer!.id,
          'protocol': _selectedProtocol.apiValue,
        });
        _xrayProtocol = result.xrayProtocol;
        _lastTunnelConnectedAt = DateTime.now();
        _startTrafficStatsMonitoring();
        _startNetworkChangeListener();
        _reconnectionAttempts = 0;
        notifyListeners();
        _log('VpnService._connectXray: Xray подключение успешно установлено');
        return true;
      }
      throw Exception('Не удалось применить Xray конфигурацию');
    } catch (e, stackTrace) {
      if (e is StaleConnectSessionException) {
        _log('VpnService._connectXray: stale session ignored at ${e.stage}');
        return false;
      }
      if (e is ConfigMismatchException) {
        _log(
          'VpnService._connectXray: CONFIG_MISMATCH correlation_id=${e.correlationId} '
          'mismatch_fields=${e.mismatchFields}',
        );
        _applyTransition(VpnConnectionState.idle);
        rethrow;
      }
      _log('VpnService._connectXray: ОШИБКА подключения Xray: $e');
      _log('VpnService._connectXray: Тип ошибки: ${e.runtimeType}');
      _log('VpnService._connectXray: Stack trace: $stackTrace');

      _applyTransition(VpnConnectionState.idle);

      // Детальная диагностика ошибки
      if (e is DioException) {
        _log(
            'VpnService._connectXray: DioException - type: ${e.type}, message: ${e.message}');
        _log(
            'VpnService._connectXray: DioException - response: ${e.response?.data}, statusCode: ${e.response?.statusCode}');
        _logXrayTiming('xray_connect_failed_dio', {
          'total_ms': totalSw.elapsedMilliseconds,
          'type': e.type.name,
          'status': e.response?.statusCode,
        });
        if (e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout) {
          throw Exception(
              'Превышено время ожидания подключения к серверу. Проверьте подключение к интернету.');
        } else if (e.type == DioExceptionType.connectionError) {
          throw Exception(
              'Ошибка подключения к серверу. Проверьте подключение к интернету и доступность сервера.');
        } else if (e.response != null) {
          final statusCode = e.response?.statusCode;
          final data = e.response?.data;
          // Сначала пробуем извлечь devices из структурированного ответа (без повторного запроса)
          if (statusCode == 400) _throwIfDeviceLimitFrom400(data);
          // API возвращает {"error": {"message": "..."}} или {"detail": "..."}
          final errorObj = data is Map ? data['error'] : null;
          final detail = data is Map
              ? (data['detail'] ??
                  (errorObj is Map ? errorObj['message'] : null) ??
                  data['message'])
              : null;
          final detailStr = (detail is String ? detail : detail?.toString()) ??
              'Ошибка подключения';
          if (detailStr.toLowerCase().contains('лимит устройств') ||
              detailStr.toLowerCase().contains('device limit')) {
            List<dynamic> devices = const [];
            try {
              devices = await fetchDevicesWithAuth();
            } catch (_) {}
            throw DeviceLimitException(
              'Достигнут лимит устройств. Удалите ненужное устройство для продолжения.',
              limit: 5,
              currentCount: devices.length,
              devices: devices,
            );
          }
          throw Exception('Сервер вернул ошибку ($statusCode): $detailStr');
        }
      } else if (e is TimeoutException) {
        _logXrayTiming('xray_connect_failed_timeout', {
          'total_ms': totalSw.elapsedMilliseconds,
        });
        throw Exception(
            'Превышено время ожидания подключения. Попробуйте еще раз.');
      }

      _logXrayTiming('xray_connect_failed', {
        'total_ms': totalSw.elapsedMilliseconds,
        'error': e.runtimeType.toString(),
        'error_detail': e.toString(),
      });
      _pendingApplyConfigRevision = null;
      _pendingApplyPhase = null;
      rethrow;
    }
  }

  Future<bool> _applyXrayConfig(String config, VpnProtocol protocol) async {
    try {
      _log('VpnService._applyXrayConfig: Начало применения Xray конфигурации');
      final result = await _xrayConnectionHandler.applyConfig(
        configJson: config,
        protocol: protocol,
        mtu: _lastMtu ?? _selectMtu(_lastNetworkType),
        connectionSessionId: _connectionSessionId,
        nativeSource: _connectionTrigger,
        onConnectStateChanged: _onNativeVpnLinkChanged,
      );
      if (result.success && result.xrayProtocol != null) {
        _xrayProtocol = result.xrayProtocol;
        _lastTunnelConnectedAt = DateTime.now();
        _log('VpnService._applyXrayConfig: ✅ Xray подключен успешно');
        return true;
      }
      _log('VpnService._applyXrayConfig: ❌ Ошибка подключения Xray');
      return false;
    } catch (e, stackTrace) {
      _log(
          'VpnService._applyXrayConfig: ОШИБКА применения Xray конфигурации: $e');
      _log('VpnService._applyXrayConfig: Тип ошибки: ${e.runtimeType}');
      _log('VpnService._applyXrayConfig: Stack trace: $stackTrace');
      if (e is VpnPermissionException) {
        rethrow;
      }
      rethrow;
    }
  }

  /// Подключение GraniWG: конфиг уже в _vpnConfig из _connectStageGetConfig.
  /// Если конфига нет — запрашиваем проверенный simple-vpn provisioning path.
  Future<bool> _connectGraniWG(String token) async {
    String? config = _vpnConfig;
    if (config == null || config.isEmpty) {
      final response = await _fetchSimpleVpnConfig(token);
      if (response.data['success'] != true) {
        throw Exception(
            response.data['detail'] ?? 'Ошибка получения конфигурации GraniWG');
      }
      final raw = response.data['config'];
      config = raw == null ? null : (raw is String ? raw : jsonEncode(raw));
      if (config == null || config.isEmpty) {
        throw Exception('Конфигурация GraniWG пуста');
      }
      _vpnConfig = config;
      final jsonConfig = response.data['json_config'];
      if (jsonConfig is Map && jsonConfig['vpn_ip'] != null) {
        _currentIpAddress = jsonConfig['vpn_ip'].toString();
      }
    }
    return _applyGraniWGConfig(config, VpnProtocol.graniwg);
  }

  /// Извлекает Endpoint (host:port) из секции [Peer] WireGuard-конфига.
  String? _parseWireGuardEndpoint(String config) {
    final peerMatch =
        RegExp(r'\[Peer\][\s\S]*?Endpoint\s*=\s*([^\s\n]+)').firstMatch(config);
    return peerMatch?.group(1)?.trim();
  }

  /// Проверяет, содержит ли конфиг параметры обфускации AmneziaWG (Jc, Jmin, Jmax, S1-S4, H1-H4).
  bool _hasAmneziaWGObfuscation(String config) {
    const awgKeys = [
      'Jc',
      'Jmin',
      'Jmax',
      'S1',
      'S2',
      'S3',
      'S4',
      'H1',
      'H2',
      'H3',
      'H4'
    ];
    final interfaceSection =
        RegExp(r'\[Interface\]([\s\S]*?)(?=\[|\z)').firstMatch(config);
    if (interfaceSection == null) return false;
    final content = interfaceSection.group(1) ?? '';
    return awgKeys.any((k) => RegExp('$k\\s*=').hasMatch(content));
  }

  /// Применение GraniWG/AmneziaWG через native MethodChannel.
  ///
  /// Android uses the embedded amneziawg-go backend. Windows delegates to the
  /// native C++ channel, which prefers AmneziaWG `tunnel.dll` via Windows
  /// Service Control Manager and keeps `awg-quick.exe` only as a debug fallback.
  Future<bool> _applyGraniWGConfig(String config, VpnProtocol protocol) async {
    if (Platform.isAndroid || Platform.isWindows) {
      final ok = await NativeVpnService.connectAmneziaWg(
        config,
        connectionSessionId: _connectionSessionId,
        source: Platform.isWindows
            ? 'desktop_windows_amneziawg'
            : 'legacy_ui_amneziawg',
      );
      if (ok) {
        _isConnected = true;
        _applyTransition(VpnConnectionState.connected);
        _startConnectionMonitoring();
        _startTrafficStatsMonitoring();
      }
      return ok;
    }
    throw UnimplementedError(
      'GraniWG is not implemented for ${Platform.operatingSystem}.',
    );
  }

  /// Legacy WireGuard plugin path removed from Android release build.
  Future<bool> _applyWireGuardConfig(String config) async {
    throw UnimplementedError(
      'Legacy WireGuard path disabled. Use simple AmneziaWG native runner.',
    );
  }

  /// Legacy desktop AmneziaWG placeholder.
  Future<bool> _applyAmneziaWGConfig(String config) async {
    throw UnimplementedError(
      'Legacy GraniWG path disabled. Use simple AmneziaWG native runner.',
    );
  }

  /// Disconnect embedded/native AmneziaWG runner.
  Future<void> _disconnectGraniWG() async {
    if (!Platform.isAndroid && !Platform.isWindows) return;
    await NativeVpnService.disconnectAmneziaWg(
      reason: 'user',
      source: Platform.isWindows
          ? 'desktop_windows_amneziawg'
          : 'legacy_ui_amneziawg',
      connectionSessionId: _connectionSessionId,
    );
  }

  /// Регистрация устройства на уровне авторизации (и при холодном старте). Параллельные вызовы
  /// с разных мест сходятся в один in-flight `/vpn/device/register` (поле `_ensureDeviceRegisterInFlight`).
  Future<void> ensureDeviceRegistered(
    String token, {
    bool verifyQuota = true,
    bool force = false,
  }) async {
    final lastEnsure = _lastEnsureDeviceRegisteredAt;
    if (!force && _deviceRegistrationDoneThisSession && lastEnsure != null) {
      final elapsed = DateTime.now().difference(lastEnsure);
      if (elapsed < _ensureDeviceRegisteredCooldown) {
        return;
      }
    }
    await (_ensureDeviceRegisterInFlight ??= _runEnsureDeviceRegistered(
      token,
      verifyQuota: verifyQuota,
      force: force,
    ));
  }

  Future<void> _runEnsureDeviceRegistered(
    String token, {
    required bool verifyQuota,
    required bool force,
  }) async {
    try {
      if (_deviceId == null) await _loadDeviceId();
      if (!force && _deviceRegistrationDoneThisSession) return;
      if (!force && await _hasFreshDeviceRegistrationCache()) {
        _deviceRegistrationDoneThisSession = true;
        _lastEnsureDeviceRegisteredAt = DateTime.now();
        _log(
          'VpnService.ensureDeviceRegistered: skip /vpn/device/register '
          '(fresh local cache)',
        );
        return;
      }
      await _registerDeviceIfNeeded(token, verifyQuota: verifyQuota);
      _lastEnsureDeviceRegisteredAt = DateTime.now();
    } finally {
      _ensureDeviceRegisterInFlight = null;
    }
  }

  String? _deviceRegistrationCacheKey() {
    final deviceId = _deviceId;
    if (deviceId == null || deviceId.isEmpty) return null;
    final user = _authService.user;
    final userKey = (user?.id.isNotEmpty == true ? user!.id : user?.email)
        ?.trim()
        .toLowerCase();
    if (userKey == null || userKey.isEmpty) return null;
    final safeUser = userKey.replaceAll(RegExp(r'[^a-z0-9_.@-]'), '_');
    final safeDevice = deviceId.replaceAll(RegExp(r'[^a-zA-Z0-9_.@-]'), '_');
    return 'device_registration_ok_v2_${safeUser}_$safeDevice';
  }

  Future<bool> _hasFreshDeviceRegistrationCache() async {
    try {
      final key = _deviceRegistrationCacheKey();
      if (key == null) return false;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final expiresAt = await _storageService.getInt('${key}_expires_at');
      if (expiresAt != null && expiresAt > nowMs) return true;

      // Backward compatibility for the previous v2 cache value: it stored
      // saved_at, not expires_at. Treat it as a 24h cache.
      final savedAt = await _storageService.getInt(key);
      if (savedAt == null || savedAt <= 0) return false;
      final legacyExpiresAt =
          savedAt + _deviceRegistrationFallbackTtl.inMilliseconds;
      return legacyExpiresAt > nowMs;
    } catch (e) {
      _log('VpnService._hasFreshDeviceRegistrationCache: $e');
      return false;
    }
  }

  DateTime _deviceRegistrationExpiresAt() {
    final now = DateTime.now();
    DateTime? accessExpiresAt;

    final subscriptionExpiresAt = _authService.subscriptionExpiresAt;
    if (_authService.hasActiveSubscription &&
        subscriptionExpiresAt != null &&
        subscriptionExpiresAt.isAfter(now)) {
      accessExpiresAt = subscriptionExpiresAt;
    }

    final trialSecondsLeft = _authService.trialSecondsLeft;
    if (trialSecondsLeft != null && trialSecondsLeft > 0) {
      final trialExpiresAt = now.add(Duration(seconds: trialSecondsLeft));
      if (accessExpiresAt == null || trialExpiresAt.isAfter(accessExpiresAt)) {
        accessExpiresAt = trialExpiresAt;
      }
    }

    final maxExpiresAt = now.add(_deviceRegistrationMaxTtl);
    if (accessExpiresAt == null || !accessExpiresAt.isAfter(now)) {
      return now.add(_deviceRegistrationFallbackTtl);
    }
    return accessExpiresAt.isBefore(maxExpiresAt)
        ? accessExpiresAt
        : maxExpiresAt;
  }

  Future<void> _markDeviceRegistrationCached() async {
    try {
      final key = _deviceRegistrationCacheKey();
      if (key == null) return;
      final expiresAt = _deviceRegistrationExpiresAt();
      await _storageService.setInt(
        key,
        DateTime.now().millisecondsSinceEpoch,
      );
      await _storageService.setInt(
        '${key}_expires_at',
        expiresAt.millisecondsSinceEpoch,
      );
    } catch (e) {
      _log('VpnService._markDeviceRegistrationCached: $e');
    }
  }

  /// Сервер для уже известного `device_id` может вернуть 200/409 без `DEVICE_LIMIT_EXCEEDED`,
  /// даже если в аккаунте больше [AuthService.maxDevices] строк (дрейф/старые данные).
  /// Сверяемся с GET `/vpn/devices` (дедуп как в API), чтобы не обходили лимит после перезапуска.
  Future<void> _verifyDeviceSlotQuotaOrThrow(String token) async {
    try {
      final devices = await fetchDevicesWithAuth(forceRefresh: true);
      final limit = _authService.maxDevices;
      if (devices.length <= limit) return;
      _log(
        'VpnService._verifyDeviceSlotQuotaOrThrow: превышение лимита '
        'count=${devices.length} limit=$limit',
      );
      throw DeviceLimitException(
        'Достигнут лимит устройств ($limit)',
        limit: limit,
        currentCount: devices.length,
        devices: devices,
      );
    } on DeviceLimitException {
      rethrow;
    } catch (e) {
      _log(
          'VpnService._verifyDeviceSlotQuotaOrThrow: пропуск (сеть/ответ): $e');
    }
  }

  /// После resume: если на сервере больше устройств, чем лимит — выставить pending для модалки лимита.
  Future<void> revalidateDeviceQuotaFromServer() async {
    if (_authService.hasPendingDeviceLimit) return;
    final token = await _getAuthToken();
    if (token == null || token.isEmpty) return;
    try {
      final devices = await fetchDevicesWithAuth(forceRefresh: true);
      final limit = _authService.maxDevices;
      if (devices.length <= limit) return;
      _authService.setPendingDeviceLimit(
        DeviceLimitException(
          'Достигнут лимит устройств ($limit)',
          limit: limit,
          currentCount: devices.length,
          devices: devices,
        ),
      );
    } catch (e) {
      _log('VpnService.revalidateDeviceQuotaFromServer: $e');
    }
  }

  Future<void> _registerDeviceIfNeeded(
    String token, {
    required bool verifyQuota,
  }) async {
    try {
      _setError(null);
      final deviceInfo = DeviceInfoPlugin();
      String platform = 'unknown';
      String deviceName = 'Unknown Device';

      if (defaultTargetPlatform == TargetPlatform.android) {
        final androidInfo = await deviceInfo.androidInfo;
        platform = 'android';
        deviceName = '${androidInfo.manufacturer} ${androidInfo.model}';
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        final iosInfo = await deviceInfo.iosInfo;
        platform = 'ios';
        deviceName = '${iosInfo.name} (${iosInfo.model})';
      } else if (Platform.isWindows) {
        final winInfo = await deviceInfo.windowsInfo;
        platform = 'windows';
        deviceName = winInfo.computerName;
      } else if (Platform.isMacOS) {
        final macInfo = await deviceInfo.macOsInfo;
        platform = 'macos';
        deviceName = macInfo.computerName;
      }

      _log(
          'VpnService._registerDeviceIfNeeded: Регистрация устройства device_id=$_deviceId, name=$deviceName, platform=$platform');
      final registerData = <String, dynamic>{
        'device_id': _deviceId,
        'name': deviceName,
        'platform': platform,
      };
      final fp = await _getFingerprintForPayload();
      if (fp != null && fp.isNotEmpty) registerData['fingerprint'] = fp;
      final response = await _apiClient.post(
        '/vpn/device/register',
        data: registerData,
        options: await _vpnApiOptions({'Authorization': 'Bearer $token'}),
      );

      _log(
          'VpnService._registerDeviceIfNeeded: ✅ Устройство успешно зарегистрировано, statusCode=${response.statusCode}');
      await _clearConfigCache();
      if (verifyQuota) {
        await _verifyDeviceSlotQuotaOrThrow(token);
      } else {
        unawaited(_verifyDeviceSlotQuotaOrThrow(token));
      }
      _deviceRegistrationDoneThisSession = true;
      await _markDeviceRegistrationCached();
    } on DioException catch (e) {
      // Проверяем статус код для определения типа ошибки
      final statusCode = e.response?.statusCode;
      final responseData = e.response?.data;
      final errorData = responseData is Map ? responseData['error'] : null;
      final errorCode = errorData is Map ? errorData['code'] as String? : null;
      final errorMessage =
          errorData is Map ? errorData['message'] as String? : null;

      if (errorCode == 'DEVICE_LIMIT_EXCEEDED') {
        final message = errorMessage ?? 'Достигнут лимит устройств (5)';
        final details = errorData is Map ? errorData['details'] : null;
        final limit = details is Map ? details['limit'] as int? : null;
        final currentCount =
            details is Map ? details['current_count'] as int? : null;
        final devices = details is Map && details['devices'] is List
            ? details['devices'] as List
            : <dynamic>[];
        _setError(message);
        notifyListeners();
        throw DeviceLimitException(
          message,
          limit: limit,
          currentCount: currentCount,
          devices: devices,
        );
      }

      if (statusCode == 409 || statusCode == 200) {
        // Устройство уже зарегистрировано или успешно зарегистрировано
        _log(
            'VpnService._registerDeviceIfNeeded: ✅ Устройство уже зарегистрировано (statusCode=$statusCode)');
        if (verifyQuota) {
          await _verifyDeviceSlotQuotaOrThrow(token);
        } else {
          unawaited(_verifyDeviceSlotQuotaOrThrow(token));
        }
        _deviceRegistrationDoneThisSession = true;
        await _markDeviceRegistrationCached();
        // НЕ очищаем кэш конфига — reconnect из кэша остаётся возможным
      } else if (statusCode == 401) {
        // Проблема с авторизацией
        _log(
            'VpnService._registerDeviceIfNeeded: ❌ ОШИБКА авторизации при регистрации устройства (statusCode=$statusCode)');
        _log('VpnService._registerDeviceIfNeeded: Токен может быть невалидным');
      } else if (e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        // Проблемы с сетью
        _log(
            'VpnService._registerDeviceIfNeeded: ⚠️ ОШИБКА сети при регистрации устройства: ${e.type}');
        _log('VpnService._registerDeviceIfNeeded: Сообщение: ${e.message}');
        _log(
            'VpnService._registerDeviceIfNeeded: Продолжаем работу, но устройство может быть не зарегистрировано');
      } else if (statusCode == 400 &&
          (errorMessage?.toLowerCase().contains('лимит устройств') == true ||
              errorMessage?.toLowerCase().contains('device limit') == true ||
              (e.message?.toLowerCase().contains('лимит устройств') ??
                  false))) {
        // Fallback: ловим лимит устройств по тексту, если структура ответа отличается
        final message =
            errorMessage ?? e.message ?? 'Достигнут лимит устройств (5)';
        _setError(message);
        notifyListeners();
        throw DeviceLimitException(message,
            limit: 5, currentCount: 5, devices: const []);
      } else {
        // Другие ошибки
        _log(
            'VpnService._registerDeviceIfNeeded: ❌ ОШИБКА регистрации устройства: ${e.message}');
        _log('VpnService._registerDeviceIfNeeded: Status code: $statusCode');
        _log(
            'VpnService._registerDeviceIfNeeded: Response: ${e.response?.data}');
      }
    } on DeviceLimitException {
      rethrow;
    } catch (e, stackTrace) {
      // Неожиданные ошибки (не лимит устройств)
      _log(
          'VpnService._registerDeviceIfNeeded: ❌ НЕОЖИДАННАЯ ошибка регистрации устройства: $e');
      _log('VpnService._registerDeviceIfNeeded: Stack trace: $stackTrace');
    }
  }

  /// Разбор тела GET `/vpn/devices`. Бэкенд отдаёт JSON-массив; при обёртках — не возвращаем «тихий» [].
  List<dynamic> _parseDevicesListResponse(dynamic data) {
    if (data == null) {
      _log('VpnService.fetchDevices: response.data == null');
      throw VpnException('Пустой ответ при загрузке устройств');
    }
    if (data is List) {
      return List<dynamic>.from(data);
    }
    if (data is Map) {
      for (final key in ['data', 'devices', 'items', 'results']) {
        final v = data[key];
        if (v is List) {
          _log('VpnService.fetchDevices: извлечён список из ключа "$key"');
          return List<dynamic>.from(v);
        }
      }
    }
    _log(
      'VpnService.fetchDevices: неожиданный тип ответа: ${data.runtimeType}',
    );
    throw VpnException('Некорректный формат ответа списка устройств');
  }

  Future<List<dynamic>> fetchDevices(String token) async {
    const maxAttempts = 3;
    final sw = Stopwatch()..start();
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final response = await _apiClient.get(
          '/vpn/devices',
          options: await _vpnApiOptions(
            {'Authorization': 'Bearer $token'},
            readHeavy: true,
          ),
        );
        final parsed = _parseDevicesListResponse(response.data);
        _lastDevicesSnapshot = List<dynamic>.from(parsed);
        _lastDevicesSnapshotAt = DateTime.now();
        final reqId = response.headers.value('x-request-id') ??
            response.requestOptions.headers['X-Request-ID']?.toString();
        sw.stop();
        _log(
          'VpnService.fetchDevices: success attempt=$attempt/$maxAttempts '
          'count=${parsed.length} total_ms=${sw.elapsedMilliseconds} '
          'request_id=${reqId ?? "-"}',
        );
        return parsed;
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        final serverTransient = status == 503 || status == 429;
        final retryable = e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.sendTimeout ||
            serverTransient;
        if (!retryable || attempt == maxAttempts) {
          final snap = _lastDevicesSnapshot;
          final snapAt = _lastDevicesSnapshotAt;
          if (snap != null &&
              snapAt != null &&
              DateTime.now().difference(snapAt) <= _devicesSnapshotTtl) {
            sw.stop();
            _log(
              'VpnService.fetchDevices: fallback stale snapshot '
              'age_ms=${DateTime.now().difference(snapAt).inMilliseconds} '
              'count=${snap.length} total_ms=${sw.elapsedMilliseconds}',
            );
            return List<dynamic>.from(snap);
          }
          rethrow;
        }
        final backoff = Duration(milliseconds: 400 * attempt);
        _log(
          'VpnService.fetchDevices: retry $attempt/$maxAttempts after ${backoff.inMilliseconds}ms (${e.type}${status != null ? ", http=$status" : ""})',
        );
        await Future.delayed(backoff);
      }
    }
    throw VpnException('Не удалось загрузить список устройств');
  }

  Future<List<dynamic>> fetchDevicesWithAuth(
      {bool forceRefresh = false}) async {
    final inFlight = _fetchDevicesInFlight;
    if (inFlight != null) {
      _log('VpnService.fetchDevicesWithAuth: dedupe join in-flight request');
      return inFlight;
    }

    if (!forceRefresh) {
      final snap = _lastDevicesSnapshot;
      final snapAt = _lastDevicesSnapshotAt;
      if (snap != null &&
          snapAt != null &&
          DateTime.now().difference(snapAt) <= _devicesFetchCooldown) {
        _log(
          'VpnService.fetchDevicesWithAuth: cooldown hit '
          'age_ms=${DateTime.now().difference(snapAt).inMilliseconds} count=${snap.length}',
        );
        return List<dynamic>.from(snap);
      }
    }

    final future = () async {
      final token = await _getAuthToken();
      if (token == null || token.isEmpty) {
        throw VpnException('Требуется авторизация');
      }
      return fetchDevices(token);
    }();
    _fetchDevicesInFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_fetchDevicesInFlight, future)) {
        _fetchDevicesInFlight = null;
      }
    }
  }

  Future<void> deactivateDevice(String token, String deviceId) async {
    await _apiClient.post(
      '/vpn/device/deactivate',
      data: {
        'device_id': deviceId,
      },
      options: await _vpnApiOptions({'Authorization': 'Bearer $token'}),
    );
  }

  Future<void> deactivateDeviceWithAuth(String deviceId) async {
    final token = await _getAuthToken();
    if (token == null || token.isEmpty) {
      throw VpnException('Требуется авторизация');
    }
    await deactivateDevice(token, deviceId);
  }

  /// Полное удаление устройства из базы (уменьшает счётчик).
  /// Возвращает количество оставшихся устройств.
  Future<int> deleteDevice(String token, String deviceId) async {
    try {
      final response = await _apiClient.post(
        '/vpn/device/delete',
        data: {'device_id': deviceId},
        options: await _vpnApiOptions({'Authorization': 'Bearer $token'}),
      );
      return (response.data?['remaining_devices'] as num?)?.toInt() ?? -1;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final body = e.response?.data;
      _log(
        'VpnService.deleteDevice: [device-delete] target_id=$deviceId '
        'local_device_id=$_deviceId http=$status body=$body',
      );
      rethrow;
    }
  }

  Future<int> deleteDeviceWithAuth(String deviceId) async {
    final token = await _getAuthToken();
    if (token == null || token.isEmpty) {
      throw VpnException('Требуется авторизация');
    }
    final remaining = await deleteDevice(token, deviceId);
    // Поддерживаем консистентный локальный snapshot, чтобы cooldown не возвращал удалённое устройство.
    final snap = _lastDevicesSnapshot;
    if (snap != null) {
      _lastDevicesSnapshot = snap
          .where((d) => (d is Map ? d['device_id'] : null) != deviceId)
          .toList();
      _lastDevicesSnapshotAt = DateTime.now();
    }
    notifyListeners();
    try {
      final refreshed = await fetchDevicesWithAuth(forceRefresh: true);
      if (refreshed.length <= _authService.maxDevices) {
        _authService.clearPendingDeviceLimit();
      }
    } catch (_) {}
    return remaining;
  }

  /// Сбрасывает сессионные флаги (вызывать при logout). Следующее подключение выполнит регистрацию устройства и sync заново.
  void resetSession() {
    _deviceRegistrationDoneThisSession = false;
    _connectionStateSyncDoneThisSession = false;
  }

  Future<void> _disconnectXray({
    String reason = VpnDisconnectReason.user,
    String source = '_disconnectXray',
  }) async {
    try {
      // Отключаем Xray протокол
      if (_xrayProtocol != null) {
        await _xrayProtocol!.disconnect();
        _xrayProtocol = null;
      }

      // Отключаем нативное VPN подключение
      await NativeVpnService.disconnect(
        reason: reason,
        source: source,
        connectionSessionId: _connectionSessionId,
      );

      // Если Kill Switch включен, блокируем интернет
      if (_killSwitchEnabled) {
        await _enableKillSwitch(
            false); // Отключаем Kill Switch при отключении VPN
      }

      // Клиента на сервере НЕ удаляем — reconnect будет мгновенным из кэша
      // (как в коммерческих VPN: persistent clients)
      _log('Xray disconnected');
    } catch (e) {
      _log('Ошибка отключения Xray: $e');
      // Продолжаем отключение даже при ошибке
    }
  }

  /// Принудительное отключение устройства на сервере без изменения локального состояния
  /// Используется для очистки состояния на сервере перед повторной попыткой подключения
  /// Восстанавливает локальное состояние «подключено», если нативный VPN уже запущен
  /// (например, после перезапуска приложения при работающем в фоне VPN или при 502 от сервера)
  Future<void> _restoreConnectionStateFromNative() async {
    if (_isConnected) return;
    try {
      final nativeConnected =
          await NativeVpnService.getNativeConnectionStatus();
      if (nativeConnected == true) {
        _log(
            'VpnService._restoreConnectionStateFromNative: VPN уже работает в фоне, восстанавливаем состояние');
        _applyTransition(VpnConnectionState.connected);
        _connectionStartTime = DateTime.now();
        _startTrafficStatsMonitoring();
        _reconnectionAttempts = 0;
        notifyListeners();
      }
    } catch (e) {
      _log(
          'VpnService._restoreConnectionStateFromNative: Ошибка проверки нативного статуса (игнорируем): $e');
    }
  }

  /// Вызывать при возврате из фона (resume). Grace period: смену сети не обрабатываем — как при закрытии приложения.
  void onAppResumedFromBackground() {
    _ignoreNetworkChangeUntil =
        DateTime.now().add(AppConfig.networkChangeIgnoreAfterResume);
    _log(
        'VpnService.onAppResumedFromBackground: grace period ${AppConfig.networkChangeIgnoreAfterResume.inSeconds}s');
  }

  /// Синхронизирует Dart UI с нативным VPN (плитка, resumed).
  ///
  /// Не выполняет [_verifyConnection]: при нативном «включено» выставляет [VpnConnectionState.connected]
  /// по [NativeVpnService.getNativeConnectionStatus]. Это намеренно (быстрый UI); полная проверка туннеля — только в connect().
  Future<void> syncConnectionStateWithNative() {
    _nativeUiSyncChain =
        _nativeUiSyncChain.catchError((Object e, StackTrace _) {
      _log(
          'VpnService.syncConnectionStateWithNative: предыдущий шаг цепочки: $e');
    }).then((_) => _syncConnectionStateWithNativeImpl());
    return _nativeUiSyncChain;
  }

  Future<void> _syncConnectionStateWithNativeImpl() async {
    try {
      final stateBefore = _currentState.name;
      final nativeConnected =
          await NativeVpnService.getNativeConnectionStatus();
      _log(
        'native_status source=sync_connection connected=$nativeConnected ui_state_before=$stateBefore',
      );
      if (nativeConnected == null) {
        _log(
          'VpnService.syncConnectionStateWithNative: нативный статус неизвестен — UI не меняем',
        );
        return;
      }
      if (nativeConnected && !_isConnected) {
        _log(
            'VpnService.syncConnectionStateWithNative: VPN включен с плитки, восстанавливаем состояние');
        _lastControlSource = VpnUiControlSource.quickTileOrSystem;
        _uiConnectIntent = VpnUiConnectIntent.none;
        _applyTransition(VpnConnectionState.connected);
        _connectionStartTime = DateTime.now();
        _startTrafficStatsMonitoring();
        _reconnectionAttempts = 0;
        _saveLastConnectedSelection();
        notifyListeners();
      } else if (!nativeConnected && _isConnected) {
        _log(
            'VpnService.syncConnectionStateWithNative: VPN отключен с плитки, обновляем состояние');
        _lastControlSource = VpnUiControlSource.quickTileOrSystem;
        _uiConnectIntent = VpnUiConnectIntent.none;
        _stopTrafficStatsMonitoring();
        _connectionProgress = null;
        _connectionStartTime = null;
        _currentIpAddress = null;
        _applyTransition(VpnConnectionState.disconnected);
        notifyListeners();
      }
      _log(
        'VpnService.syncConnectionStateWithNative: ui_state_after=${_currentState.name}',
      );
    } catch (e) {
      _log('VpnService.syncConnectionStateWithNative: Ошибка (игнорируем): $e');
    }
  }

  /// Синхронизация с сервером при старте/resume: если на сервере устройство «подключено», а локально нет
  /// (например, отключились через Quick Tile), отправляем POST disconnect.
  /// Вызывать после syncConnectionStateWithNative() при возврате из фона.
  /// [force]: true — игнорировать throttle (например сразу после resume).
  Future<void> syncConnectionStateWithServer({bool force = false}) async {
    await _syncConnectionState(force: force);
  }

  bool _shouldSkipVpnStatusSync() {
    final next = _nextVpnStatusSyncAllowedAt;
    if (next == null) return false;
    if (DateTime.now().isBefore(next)) {
      _log(
        'VpnService._syncConnectionState: пропуск по throttle до $next '
        '(failures=$_vpnStatusSyncConsecutiveFailures)',
      );
      return true;
    }
    return false;
  }

  void _scheduleNextVpnStatusSync({required bool success}) {
    final now = DateTime.now();
    if (success) {
      _vpnStatusSyncConsecutiveFailures = 0;
      _nextVpnStatusSyncAllowedAt = now.add(_vpnStatusSyncBaseInterval);
      return;
    }
    _vpnStatusSyncConsecutiveFailures =
        (_vpnStatusSyncConsecutiveFailures + 1).clamp(0, 8);
    final exp = _vpnStatusSyncConsecutiveFailures.clamp(1, 4);
    final mult = 1 << (exp - 1);
    var sec = _vpnStatusSyncBaseInterval.inSeconds * mult;
    if (sec > _vpnStatusSyncMaxBackoff.inSeconds) {
      sec = _vpnStatusSyncMaxBackoff.inSeconds;
    }
    _nextVpnStatusSyncAllowedAt = now.add(Duration(seconds: sec));
  }

  /// Синхронизирует состояние подключения с сервером
  /// Проверяет, не подключено ли устройство на сервере, и синхронизирует локальное состояние
  Future<void> _syncConnectionState({bool force = false}) async {
    if (_isConnectFlowGateActive() || _disconnectInProgress) {
      _log(
        'VpnService._syncConnectionState: пропуск — '
        'идёт transition (connect/disconnect)',
      );
      return;
    }
    if (_deviceId == null) {
      _log('VpnService._syncConnectionState: deviceId отсутствует, пропускаем');
      return;
    }
    if (!force && _shouldSkipVpnStatusSync()) {
      return;
    }
    if (_vpnStatusSyncInFlight) {
      _log(
          'VpnService._syncConnectionState: пропуск — уже выполняется другой /vpn/status');
      return;
    }

    _vpnStatusSyncInFlight = true;
    _vpnStatusSyncFlightStartedAt = DateTime.now();
    try {
      final token = await _getAuthToken();
      if (token == null || token.isEmpty) {
        _log(
            'VpnService._syncConnectionState: Токен отсутствует, пропускаем синхронизацию');
        return;
      }

      _log(
          'VpnService._syncConnectionState: Проверка состояния подключения на сервере...');
      _log(
          'VpnService._syncConnectionState: Текущее состояние: _isConnected=$_isConnected, _isConnecting=$_isConnecting');

      // Проверяем состояние подключения на сервере
      try {
        final statusWall = await NetworkTimeouts.vpnStatusWallTimeout();
        final response = await _apiClient
            .get(
          '/vpn/status',
          queryParameters: {
            'device_id': _deviceId,
          },
          options: await _vpnApiOptions(
            {'Authorization': 'Bearer $token'},
            readHeavy: true,
          ),
        )
            .timeout(
          statusWall,
          onTimeout: () {
            _log(
                'VpnService._syncConnectionState: ⚠️ Таймаут запроса /vpn/status (${statusWall.inSeconds} с)');
            throw TimeoutException('Таймаут проверки состояния');
          },
        );

        if (response.statusCode == 200) {
          final isConnectedOnServer = response.data['connected'] == true;
          _log(
              'VpnService._syncConnectionState: Состояние на сервере: connected=$isConnectedOnServer, локальное: _isConnected=$_isConnected');

          // Если на сервере подключено, а локально нет - отключаем на сервере
          if (isConnectedOnServer && !_isConnected) {
            _log(
                'VpnService._syncConnectionState: ⚠️ Несоответствие состояния - отключаем на сервере');
            final disconnectStartTime = DateTime.now();
            try {
              final disconnectSuccess =
                  await _forceDisconnectOnServer(token).timeout(
                const Duration(seconds: 6),
                onTimeout: () {
                  _log(
                      'VpnService._syncConnectionState: ⚠️ Таймаут _forceDisconnectOnServer (6 секунд)');
                  _applyTransition(VpnConnectionState.idle);
                  return false;
                },
              );
              final disconnectDuration =
                  DateTime.now().difference(disconnectStartTime);
              _log(
                  'VpnService._syncConnectionState: Отключение на сервере завершено за ${disconnectDuration.inMilliseconds}ms, успех: $disconnectSuccess');
            } catch (e) {
              _log(
                  'VpnService._syncConnectionState: Ошибка при отключении на сервере: $e');
              _applyTransition(VpnConnectionState.idle);
            }
          } else {
            _log(
                'VpnService._syncConnectionState: ✅ Состояние синхронизировано (сервер: $isConnectedOnServer, локально: $_isConnected)');
          }
          _scheduleNextVpnStatusSync(success: true);
        } else {
          _scheduleNextVpnStatusSync(success: false);
        }
      } on DioException catch (e) {
        // Если эндпоинт не существует (404) или неверный запрос (422/400) - игнорируем
        if (e.response?.statusCode == 404 || e.response?.statusCode == 422) {
          _log(
              'VpnService._syncConnectionState: Эндпоинт /vpn/status не найден или неверный запрос (${e.response?.statusCode}), пропускаем');
          _scheduleNextVpnStatusSync(success: true);
        } else {
          _log(
              'VpnService._syncConnectionState: Ошибка проверки состояния (игнорируем): ${e.response?.statusCode}');
          if (e.response?.statusCode == 400) {
            _log(
                'VpnService._syncConnectionState: тело ответа 400: ${e.response?.data}');
          }
          _scheduleNextVpnStatusSync(success: false);
        }
      } on TimeoutException catch (e) {
        _log('VpnService._syncConnectionState: Таймаут проверки состояния: $e');
        _scheduleNextVpnStatusSync(success: false);
        // Не блокируем подключение при таймауте
      }
    } catch (e) {
      _log(
          'VpnService._syncConnectionState: Ошибка синхронизации состояния (игнорируем): $e');
      _scheduleNextVpnStatusSync(success: false);
      _applyTransition(VpnConnectionState.idle);
    } finally {
      final started = _vpnStatusSyncFlightStartedAt;
      final wallMs = started != null
          ? DateTime.now().difference(started).inMilliseconds
          : -1;
      if (wallMs >= 0) {
        _lastConnectionTimingMs['vpn_status_sync_wall_ms'] = wallMs;
      }
      _log(
        'VpnService._syncConnectionState: sync flight end path_free_for_connect '
        'duration_ms=$wallMs',
      );
      _vpnStatusSyncFlightStartedAt = null;
      _vpnStatusSyncInFlight = false;
    }
  }

  /// Принудительное отключение устройства на сервере
  /// Возвращает true если отключение успешно, false в случае ошибки
  Future<bool> _forceDisconnectOnServer(String token,
      {bool force = false}) async {
    if (_deviceId == null) {
      _log('VpnService._forceDisconnectOnServer: ❌ device_id отсутствует');
      _logger.warning('device_id отсутствует');
      return false;
    }

    final startTime = DateTime.now();
    try {
      _log(
          'VpnService._forceDisconnectOnServer: Начало отключения на сервере (device_id: $_deviceId, force: $force)');
      _logger.debug(
          'Принудительное отключение устройства на сервере (device_id: $_deviceId, force: $force)');
      final response = await _apiClient.post(
        '/vpn/disconnect',
        data: {
          'device_id': _deviceId,
          'force': force, // Используем force для принудительного отключения
        },
        options: await _vpnApiOptions({'Authorization': 'Bearer $token'}),
      );

      final duration = DateTime.now().difference(startTime);
      if (response.statusCode == 200 || response.statusCode == 204) {
        _log(
            'VpnService._forceDisconnectOnServer: ✅ Устройство успешно отключено на сервере за ${duration.inMilliseconds}ms');
        _logger.debug('Устройство успешно отключено на сервере');
        return true;
      } else {
        _log(
            'VpnService._forceDisconnectOnServer: ⚠️ Неожиданный статус код: ${response.statusCode} (время: ${duration.inMilliseconds}ms)');
        _logger.warning('Неожиданный статус код: ${response.statusCode}');
        return false;
      }
    } on DioException catch (e) {
      final duration = DateTime.now().difference(startTime);
      // Если устройство уже отключено (404) или нет доступа (403) - считаем успехом
      if (e.response?.statusCode == 404 || e.response?.statusCode == 403) {
        _log(
            'VpnService._forceDisconnectOnServer: ✅ Устройство уже отключено или нет доступа (status: ${e.response?.statusCode}, время: ${duration.inMilliseconds}ms)');
        _logger.debug(
            'Устройство уже отключено или нет доступа (status: ${e.response?.statusCode})');
        return true;
      }

      // Для ошибки 500 - пробуем принудительное отключение
      if (e.response?.statusCode == 500 && !force) {
        _log(
            'VpnService._forceDisconnectOnServer: ⚠️ Сервер вернул ошибку 500 при отключении, пробуем force=true (время: ${duration.inMilliseconds}ms)');
        _logger.warning(
            'Сервер вернул ошибку 500 при отключении, пробуем принудительное отключение');
        // Пробуем принудительное отключение
        return await _forceDisconnectOnServer(token, force: true);
      }

      // Если force=true и все равно ошибка - считаем частичным успехом
      // (состояние в БД должно быть очищено)
      if (e.response?.statusCode == 500 && force) {
        _log(
            'VpnService._forceDisconnectOnServer: ⚠️ Сервер вернул ошибку 500 даже при force=true (время: ${duration.inMilliseconds}ms)');
        _log(
            'VpnService._forceDisconnectOnServer: Считаем частичным успехом - состояние в БД должно быть очищено');
        _logger.warning(
            'Сервер вернул ошибку 500 даже при force=true, но состояние в БД должно быть очищено');
        return true; // Возвращаем true, чтобы попробовать подключиться снова
      }

      // Для других ошибок логируем детали
      _log(
          'VpnService._forceDisconnectOnServer: ❌ Ошибка принудительного отключения: ${e.message} (status: ${e.response?.statusCode}, время: ${duration.inMilliseconds}ms)');
      _logger.error('Ошибка принудительного отключения', 'VpnService', e);
      if (e.response != null) {
        _log(
            'VpnService._forceDisconnectOnServer: Response data: ${e.response?.data}');
        _logger.debug('Response data: ${e.response?.data}');
      }
      return false;
    } catch (e) {
      final duration = DateTime.now().difference(startTime);
      _log(
          'VpnService._forceDisconnectOnServer: ❌ Неожиданная ошибка: $e (время: ${duration.inMilliseconds}ms)');
      _logger.error(
          'Неожиданная ошибка принудительного отключения', 'VpnService', e);
      return false;
    }
  }

  // Kill Switch функции
  Future<void> enableKillSwitch(bool enable) async {
    _killSwitchEnabled = enable;
    await _enableKillSwitch(enable);
    notifyListeners();
  }

  bool get killSwitchEnabled => _killSwitchEnabled;

  Future<void> _enableKillSwitch(bool enable) async {
    try {
      // В реальной реализации здесь будет блокировка интернета через нативный VPN сервис
      // или системные настройки
      if (enable) {
        _log(
            'Kill Switch включен: интернет будет заблокирован при отключении VPN');
        // Реализация блокировки интернета
        // await NativeVpnService.enableKillSwitch(true);
      } else {
        _log('Kill Switch выключен');
        // await NativeVpnService.enableKillSwitch(false);
      }
    } catch (e) {
      _log('Ошибка управления Kill Switch: $e');
    }
  }

  // Split Tunneling функции
  void setSplitTunnelingApps(List<String> appPackageNames) {
    _splitTunnelingApps = appPackageNames;
    notifyListeners();
  }

  List<String> get splitTunnelingApps => _splitTunnelingApps;

  Future<void> applySplitTunneling() async {
    try {
      if (_splitTunnelingApps.isEmpty) {
        // Если список пуст, все приложения идут через VPN
        _log('Split Tunneling: все приложения используют VPN');
        return;
      }

      _log(
          'Split Tunneling: ${_splitTunnelingApps.length} приложений исключены из VPN');
      // В реальной реализации здесь будет применение настроек Split Tunneling
      // через нативный VPN сервис
      // await NativeVpnService.setSplitTunnelingApps(_splitTunnelingApps);
    } catch (e) {
      _log('Ошибка применения Split Tunneling: $e');
    }
  }

  Future<void> selectServer(Server server) async {
    if (_minimalVpnMode) {
      _forceMinimalVpnSelection(reason: 'select_server_ignored');
      notifyListeners();
      return;
    }
    // Если подключены или идет подключение/отключение, сначала отключаемся
    if (_isConnected || _isConnecting || _isDisconnecting) {
      _log('VpnService.selectServer: Отключаемся перед сменой сервера...');
      await disconnect(
        reason: VpnDisconnectReason.serverSwitch,
        source: 'select_server',
      );

      // Дополнительная проверка - ждем завершения отключения
      int attempts = 0;
      while ((_isConnecting || _isConnected || _isDisconnecting) &&
          attempts < AppConfig.selectServerWaitDisconnectMaxAttempts) {
        await Future.delayed(AppConfig.selectServerWaitDisconnectStep);
        attempts++;
      }

      // При истечении таймаута локальное состояние принудительно считаем отключённым; смена сервера выполняется.
      // API/сервер при необходимости остаётся в старом состоянии до следующего connect/disconnect.
      if (_isConnecting || _isConnected || _isDisconnecting) {
        _log(
            'VpnService.selectServer: ⚠️ Отключение не завершилось, но продолжаем смену сервера');
        if (_currentState == VpnConnectionState.disconnecting) {
          _applyTransition(VpnConnectionState.disconnected);
        }
      }
    }

    _selectedServer = server;
    _vpnConfig = null;
    _clientId = null;
    _currentIpAddress = null;
    await _clearConfigCache();
    // Синхрон с модалкой протоколов: при смене сервера ставим первый в списке (Xray → … → WireGuard)
    final best = _findBestProtocol(server);
    if (best != null) {
      _selectedProtocol = best;
      _log(
          'VpnService.selectServer: Протокол синхронизирован с порядком в модалке: ${_selectedProtocol.name}');
    }
    notifyListeners();
    _log('VpnService.selectServer: Сервер изменен на ${server.id}');
    await _persistUserUiSelectionToStorage(reason: 'select_server');
  }

  /// Получает токен авторизации из AuthService. Не вызывает ensureValidToken —
  /// ApiClient при 401 сам обновит токен и повторит запрос.
  Future<String?> _getAuthToken() async {
    try {
      final token = _authService.token;
      if (token != null && token.isNotEmpty) return token;
    } catch (e) {
      _logger.error(
          'Ошибка получения токена через AuthService', 'VpnService', e);
    }
    try {
      String? token = await _storageService.getSecureString('auth_token');
      if (token == null) {
        token = await _storageService.getString('auth_token');
        if (token != null) {
          _logger.debug(
              'Токен найден в обычном хранилище (legacy), мигрируем в SecureStorage');
          await _storageService.setSecureString('auth_token', token);
          await _storageService.remove('auth_token');
        }
      }
      return token;
    } catch (e) {
      _logger.error('Ошибка чтения токена из хранилища', 'VpnService', e);
      return null;
    }
  }

  Future<void> refreshServers({bool force = false}) async {
    final perfLogger = PerfLogger();
    final stopwatch = Stopwatch()..start();
    String outcome = 'success';
    int? serverCount;
    const isDebug = kDebugMode;

    // Debounce: предотвращаем дублирующие запросы
    if (_isRefreshing) {
      _log('VpnService.refreshServers: ⏳ Запрос уже выполняется, пропускаем');
      return;
    }

    // Проверяем минимальный интервал между запросами (если не force)
    if (!force && _lastRefreshTime != null) {
      final timeSinceLastRefresh = DateTime.now().difference(_lastRefreshTime!);
      if (timeSinceLastRefresh < _refreshDebounceInterval) {
        _log(
            'VpnService.refreshServers: ⏳ Слишком частые запросы (${timeSinceLastRefresh.inMilliseconds}ms), пропускаем');
        return;
      }
    }

    _isRefreshing = true;
    _lastRefreshTime = DateTime.now();

    try {
      _log('VpnService.refreshServers: Начало загрузки серверов');

      // Получаем токен авторизации
      final token = await _getAuthToken();

      if (token == null || token.isEmpty) {
        _log(
            'VpnService.refreshServers: ⚠️ Токен отсутствует - загружаем из кэша');
        // Не очищаем список серверов, пытаемся загрузить из кэша
        await _loadServersFromCache();
        notifyListeners();
        return;
      }
      final tokenPreview = token.length > 10 ? token.substring(0, 10) : token;
      _log(
          'VpnService.refreshServers: Токен получен (длина: ${token.length}), первые 10 символов: $tokenPreview...');
      _log('VpnService.refreshServers: API Base URL: ${AppConfig.apiBaseUrl}');
      _log(
          'VpnService.refreshServers: Полный URL: ${AppConfig.apiBaseUrl}/vpn/servers');

      final response = await _apiClient.get(
        '/vpn/servers',
        options: await _vpnApiOptions(
          {'Authorization': 'Bearer $token'},
          readHeavy: true,
        ),
      );

      _log(
          'VpnService.refreshServers: Ответ получен: statusCode=${response.statusCode}');
      if (isDebug) {
        _log(
            'VpnService.refreshServers: Тип данных: ${response.data.runtimeType}');
        _log('VpnService.refreshServers: Полный ответ API: ${response.data}');
      }

      // Дополнительная проверка: если ответ не список, логируем детали
      if (response.statusCode == 200 && response.data is! List) {
        _log(
            'VpnService.refreshServers: ⚠️ ВНИМАНИЕ: API вернул статус 200, но данные не список');
        _log(
            'VpnService.refreshServers: Тип данных: ${response.data.runtimeType}');
        if (response.data is Map) {
          _log(
              'VpnService.refreshServers: Ключи в ответе: ${(response.data as Map).keys.toList()}');
        }
      }

      if (response.statusCode == 200 && response.data is List) {
        final responseList = response.data as List;
        _log(
            'VpnService.refreshServers: Количество серверов в ответе: ${responseList.length}');
        if (responseList.isNotEmpty && isDebug) {
          _log(
            'VpnService.refreshServers: Первый сервер (redacted): ${VpnLogRedaction.redactForLog(responseList.first)}',
          );
        }

        // Обрабатываем каждый сервер отдельно с обработкой ошибок
        final allServers = <Server>[];
        for (var json in responseList) {
          try {
            _log(
                'VpnService.refreshServers: Обрабатываем сервер: id=${json['id']}, name=${json['name']}, protocols=${json['supported_protocols']}');
            if (isDebug) {
              _log(
                'VpnService.refreshServers: Полные данные сервера (redacted): ${VpnLogRedaction.redactForLog(json)}',
              );
            }

            // Проверяем наличие обязательных полей
            if (json['wireguard_public_key'] == null ||
                (json['wireguard_public_key'] as String).isEmpty) {
              _log(
                  'VpnService.refreshServers: ПРЕДУПРЕЖДЕНИЕ - у сервера ${json['id']} отсутствует wireguard_public_key');
            }

            final raw = Map<String, dynamic>.from(json as Map);
            final server = Server.fromJson(raw);
            allServers.add(server);
            _log(
                'VpnService.refreshServers: Сервер ${server.id} успешно загружен: name=${server.name}, country=${server.country}, city=${server.city}, wireguard_public_key=${server.wireguardPublicKey != null ? "установлен" : "отсутствует"}');
          } catch (e, stackTrace) {
            _log(
                'VpnService.refreshServers: ОШИБКА парсинга сервера ${json['id']}: $e');
            _log(
              'VpnService.refreshServers: Данные сервера (redacted): ${VpnLogRedaction.redactForLog(json)}',
            );
            _log('VpnService.refreshServers: Stack trace: $stackTrace');
            // Продолжаем обработку остальных серверов
          }
        }

        // Фильтруем только активные серверы
        // Для WireGuard требуется wireguard_public_key, для Xray нет
        _servers = allServers.where((server) {
          if (!server.isActive) {
            _log(
                'VpnService.refreshServers: Сервер ${server.id} отфильтрован: неактивен');
            return false;
          }

          final protocols = server.supportedProtocols ?? ['xray_reality'];

          final hasWireguard = protocols.contains('wireguard');
          final hasXray = protocols.any((p) => p.startsWith('xray_'));

          if (!hasWireguard && !hasXray) {
            _log(
                'VpnService.refreshServers: Сервер ${server.id} отфильтрован: нет WireGuard/Xray');
            return false;
          }

          if (hasWireguard &&
              (server.wireguardPublicKey == null ||
                  server.wireguardPublicKey!.isEmpty) &&
              !hasXray) {
            _log(
                'VpnService.refreshServers: Сервер ${server.id} отфильтрован: WireGuard без ключа');
            return false;
          }

          return true;
        }).toList();

        _log(
            'VpnService.refreshServers: После фильтрации осталось ${_servers.length} серверов из ${allServers.length}');

        // КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: Если после фильтрации список пуст, но есть активные серверы - используем fallback
        if (_servers.isEmpty && allServers.isNotEmpty) {
          _log(
              'VpnService.refreshServers: ⚠️ КРИТИЧЕСКАЯ ПРОБЛЕМА - все серверы отфильтрованы');
          _log(
              'VpnService.refreshServers: Всего серверов до фильтрации: ${allServers.length}');

          // Логируем детали каждого сервера только в debug режиме
          if (isDebug) {
            _log(
                'VpnService.refreshServers: 📋 Детали серверов до фильтрации:');
            for (var server in allServers) {
              final protocols = server.supportedProtocols ?? ['xray_reality'];
              final hasKey = server.wireguardPublicKey != null &&
                  server.wireguardPublicKey!.isNotEmpty;
              _log(
                  'VpnService.refreshServers:   - Сервер ${server.id} (${server.name}):');
              _log(
                  'VpnService.refreshServers:     isActive=${server.isActive}');
              _log(
                  'VpnService.refreshServers:     supportedProtocols=$protocols');
              _log('VpnService.refreshServers:     hasWireguardKey=$hasKey');
              if (!server.isActive) {
                _log(
                    'VpnService.refreshServers:     ❌ Отфильтрован: неактивен');
              } else if (protocols.contains('wireguard') &&
                  !hasKey &&
                  !protocols.any((p) => p.startsWith('xray_'))) {
                _log(
                    'VpnService.refreshServers:     ❌ Отфильтрован: WireGuard без ключа и нет Xray');
              } else if (!protocols.contains('wireguard') &&
                  !protocols.any((p) => p.startsWith('xray_'))) {
                _log(
                    'VpnService.refreshServers:     ❌ Отфильтрован: нет WireGuard/Xray');
              } else {
                _log(
                    'VpnService.refreshServers:     ✅ Сервер должен быть доступен, но был отфильтрован (неизвестная причина)');
              }
            }
          }

          // FALLBACK: Показываем все активные серверы, даже если у них нет ключа
          // Это позволит пользователю видеть серверы и выбирать протоколы, которые не требуют ключа
          try {
            final activeServers = allServers.where((s) => s.isActive).toList();
            if (activeServers.isNotEmpty) {
              _log(
                  'VpnService.refreshServers: 🔄 FALLBACK: Используем ${activeServers.length} активных серверов');
              for (var server in activeServers) {
                _log(
                    'VpnService.refreshServers:   - Сервер ${server.id} (${server.name}): protocols=${server.supportedProtocols}');
              }
              _log(
                  'VpnService.refreshServers: ⚠️ ВНИМАНИЕ: Некоторые серверы могут не поддерживать все протоколы');
              _servers = activeServers;
            } else {
              // Если нет активных серверов, используем первый неактивный
              _log(
                  'VpnService.refreshServers: 🔄 FALLBACK: Нет активных серверов, используем первый сервер');
              _servers = [allServers.first];
            }
          } catch (e) {
            _log(
                'VpnService.refreshServers: ❌ ОШИБКА: Не удалось найти fallback сервер: $e');
          }
        } else if (_servers.isEmpty && allServers.isEmpty) {
          _log(
              'VpnService.refreshServers: ❌ Серверы не были загружены из API (пустой ответ)');
        } else {
          _log(
              'VpnService.refreshServers: ✅ Успешно загружено ${_servers.length} серверов');
          for (var server in _servers) {
            _log(
                'VpnService.refreshServers:   ✓ Сервер ${server.id} (${server.name}): protocols=${server.supportedProtocols}');
          }
        }

        if (_servers.isNotEmpty) {
          try {
            _servers = await enrichServersWithClientPing(_servers);
            _log(
                'VpnService.refreshServers: клиентский TCP-замер для серверов без ping_ms завершён');
          } catch (e) {
            _log(
                'VpnService.refreshServers: клиентский TCP-замер пропущен: $e');
          }
        }

        // Minimal VPN keeps a fixed server/protocol after auth.
        if (_minimalVpnMode) {
          _forceMinimalVpnSelection(reason: 'refresh_servers');
        } else if (_selectedServer != null) {
          final found = _servers.firstWhere(
            (s) => s.id == _selectedServer!.id,
            orElse: () =>
                _servers.isNotEmpty ? _servers.first : _selectedServer!,
          );
          _selectedServer = found;
          _log(
              'VpnService.refreshServers: Выбранный сервер: ${_selectedServer!.id} (${_selectedServer!.name})');
        } else if (_servers.isNotEmpty) {
          await _restoreLastConnectedSelection();
          if (_selectedServer == null) {
            _selectedServer = _servers.first;
            _log(
                'VpnService.refreshServers: Автоматически выбран первый сервер: ${_selectedServer!.id} (${_selectedServer!.name})');
            final best = _findBestProtocol(_selectedServer!);
            if (best != null) {
              _selectedProtocol = best;
              _log(
                  'VpnService.refreshServers: Протокол синхронизирован с порядком в модалке: ${_selectedProtocol.name}');
            }
          }
        } else {
          _log(
              'VpnService.refreshServers: ПРЕДУПРЕЖДЕНИЕ - список серверов пуст');
        }

        // Сохраняем успешно загруженный список в кэш
        await _saveServersToCache(_servers);
        _log('VpnService.refreshServers: ✅ Список серверов сохранен в кэш');
      } else {
        _log('VpnService.refreshServers: ❌ ОШИБКА - неверный формат ответа');
        _log('VpnService.refreshServers: statusCode=${response.statusCode}');
        _log(
            'VpnService.refreshServers: Тип данных: ${response.data.runtimeType}');
        _log('VpnService.refreshServers: Данные: ${response.data}');

        // Если статус 200, но данные не список - это проблема API
        if (response.statusCode == 200) {
          _log(
              'VpnService.refreshServers: ⚠️ API вернул статус 200, но данные не в формате списка');
          _log(
              'VpnService.refreshServers: Ожидался List, получен: ${response.data.runtimeType}');
        }

        // Не очищаем список, пытаемся загрузить из кэша
        if (_servers.isEmpty) {
          await _loadServersFromCache();
        }
      }
    } catch (e, stackTrace) {
      outcome = 'error';
      _log('VpnService.refreshServers: ❌ ОШИБКА загрузки серверов: $e');
      _log('VpnService.refreshServers: Тип ошибки: ${e.runtimeType}');
      if (e is DioException) {
        _log('VpnService.refreshServers: DioException details:');
        _log(
            'VpnService.refreshServers:   - Response status: ${e.response?.statusCode}');
        _log(
            'VpnService.refreshServers:   - Response data: ${e.response?.data}');
        _log(
            'VpnService.refreshServers:   - Request path: ${e.requestOptions.path}');
        _log(
            'VpnService.refreshServers:   - Request headers: ${e.requestOptions.headers}');
        if (e.response?.statusCode == 401) {
          _log(
              'VpnService.refreshServers: ⚠️ Ошибка авторизации (401) - возможно, токен невалиден или истек');
        } else if (e.response?.statusCode == 403) {
          _log('VpnService.refreshServers: ⚠️ Доступ запрещен (403)');
        }
      }
      _log('VpnService.refreshServers: Stack trace: $stackTrace');

      // Не очищаем список при ошибке, пытаемся загрузить из кэша
      if (_servers.isEmpty) {
        await _loadServersFromCache();
      }
    } finally {
      serverCount ??= _servers.length;
      _isRefreshing = false;
      stopwatch.stop();
      perfLogger
          .record('refresh_servers', stopwatch.elapsedMilliseconds, details: {
        'outcome': outcome,
        'servers': serverCount,
      });
    }

    notifyListeners();
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
      }

      authService.notifyListeners();
      notifyListeners();
    } catch (e) {
      _log('VpnService.refreshControlPlaneSnapshot: $e');
    } finally {
      _isRefreshing = false;
    }
  }

  Future<void> loadServers() async {
    await refreshServers();
  }

  /// Сохраняет список серверов в кэш (SharedPreferences)
  Future<void> _saveServersToCache(List<Server> servers) async {
    try {
      final serversJson = servers.map((server) => server.toJson()).toList();
      final serversJsonString = jsonEncode(serversJson);
      // Кэш серверов валиден 24 часа
      await _cacheService.setString('cached_servers', serversJsonString,
          ttl: const Duration(hours: 24));
      _logger.debug('Сохранено ${servers.length} серверов в кэш');
    } catch (e) {
      _logger.error('Ошибка сохранения в кэш', 'VpnService', e);
    }
  }

  /// Загружает список серверов из кэша
  Future<void> _loadServersFromCache() async {
    try {
      final serversJsonString = await _cacheService.getString('cached_servers');

      if (serversJsonString == null || serversJsonString.isEmpty) {
        _logger.debug('Кэш серверов пуст');
        return;
      }

      // Проверяем валидность кэша (TTL 24 часа)
      final isValid = await _cacheService.isValid('cached_servers');
      if (!isValid) {
        _logger.debug('Кэш серверов истек, игнорируем');
        await _cacheService.remove('cached_servers');
        return;
      }

      final age = await _cacheService.getAge('cached_servers');
      if (age != null) {
        final cacheAgeHours = age / 3600;
        _logger
            .debug('Возраст кэша: ${cacheAgeHours.toStringAsFixed(2)} часов');
      }

      final serversJson = jsonDecode(serversJsonString) as List;
      final cachedServers = serversJson
          .map((json) => Server.fromJson(json as Map<String, dynamic>))
          .toList();

      if (cachedServers.isNotEmpty) {
        _servers = cachedServers;
        _logger.debug('Загружено ${_servers.length} серверов из кэша');

        // Восстанавливаем выбранный сервер: сначала из памяти, иначе из последнего подключения, иначе первый
        if (_selectedServer != null) {
          final found = _servers.firstWhere(
            (s) => s.id == _selectedServer!.id,
            orElse: () =>
                _servers.isNotEmpty ? _servers.first : _selectedServer!,
          );
          _selectedServer = found;
        } else if (_servers.isNotEmpty) {
          await _restoreLastConnectedSelection();
          if (_selectedServer == null) {
            _selectedServer = _servers.first;
            final best = _findBestProtocol(_servers.first);
            if (best != null) _selectedProtocol = best;
          }
        }
      } else {
        _logger.debug('Кэш пуст после парсинга');
      }
    } catch (e, stackTrace) {
      _logger.error('Ошибка загрузки из кэша', 'VpnService', e, stackTrace);
    }
  }

  Duration get connectionDuration {
    if (_connectionStartTime == null) return Duration.zero;
    return DateTime.now().difference(_connectionStartTime!);
  }

  /// Запрос разрешения VPN у пользователя
  /// Возвращает true если разрешение уже есть или получено, false если отклонено
  /// Android: интервал нативных тиков трафика (1 с / 4 с). Вызывать из [WidgetsBindingObserver] (paused vs resumed).
  Future<void> setNativeTrafficTelemetryForAppLifecycle(
      {required bool inBackground}) async {
    await NativeVpnService.setVpnTrafficTelemetryBackgroundMode(inBackground);
  }

  Future<bool> requestVpnPermission() async {
    try {
      _log('VpnService: Запрос разрешения VPN');
      final result = await NativeVpnService.requestVpnPermission();
      _log('VpnService: Результат запроса разрешения: $result');
      return result;
    } catch (e) {
      _log('VpnService: Ошибка запроса разрешения VPN: $e');
      if (e is VpnPermissionException) {
        rethrow;
      }
      return false;
    }
  }

  /// Начинает мониторинг статистики трафика
  void _startTrafficStatsMonitoring() {
    _stopTrafficStatsMonitoring(); // Останавливаем предыдущий таймер, если есть
    _trafficMonitorChannelStatsStart =
        Map<String, int>.from(NativeVpnService.channelCallSnapshot());
    _totalBytesReceived = 0;
    _totalBytesSent = 0;
    _prevTotalBytesForSpeed = 0;
    _prevTrafficStatsTime = null;
    _currentSpeedMbps = null;
    _hasEverSeenTraffic = false;

    // Android: трафик приходит с нативного слоя (emit_type=traffic) раз в 1 с, без Dart-polling getTrafficStats.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _log(
        'VpnService: Мониторинг трафика — нативные события (EventChannel); '
        'safety: sync после 60 с тишины (таймер сбрасывается на каждое нативное событие)',
      );
    } else {
      _trafficStatsTimer =
          Timer.periodic(const Duration(seconds: 1), (timer) async {
        if (!_isConnected) {
          _stopTrafficStatsMonitoring();
          return;
        }

        try {
          final stats = await NativeVpnService.getTrafficStats();
          _applyTrafficSnapshotFromNative(<dynamic, dynamic>{
            'rx_bytes': stats['rx_bytes'] ?? 0,
            'tx_bytes': stats['tx_bytes'] ?? 0,
          });
        } catch (e) {
          _log('VpnService: Ошибка получения статистики трафика: $e');
        }
      });
      _log(
          'VpnService: Мониторинг статистики трафика (1s Dart timer, non-Android)');
    }

    _startNativeConnectedSafetyPoll();
  }

  void _startNativeConnectedSafetyPoll() {
    _touchNativeConnectedSafetyPoll();
  }

  /// Однократный таймер: если за [_nativeConnectedSafetyInterval] не было ни одного нативного события — [syncConnectionStateWithNative].
  void _touchNativeConnectedSafetyPoll() {
    _nativeConnectedSafetyTimer?.cancel();
    if (!_isConnected) {
      _nativeConnectedSafetyTimer = null;
      return;
    }
    _nativeConnectedSafetyTimer = Timer(_nativeConnectedSafetyInterval, () {
      _nativeConnectedSafetyTimer = null;
      if (!_isConnected) return;
      unawaited(
        syncConnectionStateWithNative().whenComplete(() {
          if (_isConnected) {
            _touchNativeConnectedSafetyPoll();
          }
        }),
      );
    });
  }

  void _stopNativeConnectedSafetyPoll() {
    _nativeConnectedSafetyTimer?.cancel();
    _nativeConnectedSafetyTimer = null;
  }

  /// Останавливает мониторинг статистики трафика
  void _stopTrafficStatsMonitoring() {
    final start = _trafficMonitorChannelStatsStart;
    if (start != null) {
      final end = NativeVpnService.channelCallSnapshot();
      final ds = (end['getStatus'] ?? 0) - (start['getStatus'] ?? 0);
      final dt =
          (end['getTrafficStats'] ?? 0) - (start['getTrafficStats'] ?? 0);
      if (ds > 0 || dt > 0) {
        _log(
          '[vpn-native-channels] за интервал мониторинга трафика: getStatus+$ds getTrafficStats+$dt (MethodChannel)',
        );
      }
    }
    _trafficMonitorChannelStatsStart = null;
    _trafficStatsTimer?.cancel();
    _trafficStatsTimer = null;
    _stopNativeConnectedSafetyPoll();
    _resetPostConnectCommitState();
    _currentSpeedMbps = null;
    _hasEverSeenTraffic = false;
    _log('VpnService: Мониторинг статистики трафика остановлен');
  }

  /// Начинает мониторинг для автопереподключения: без polling — только события [NativeVpnService.nativeVpnStateEvents].
  void _startConnectionMonitoring() {
    _stopConnectionMonitoring();
    _autoReconnectEnabled = true;
    _reconnectionAttempts = 0;
    _log('VpnService: Мониторинг подключения (event-driven) включён');
  }

  /// Останавливает мониторинг подключения
  void _stopConnectionMonitoring() {
    _autoReconnectEnabled = false;
    _log('VpnService: Мониторинг подключения остановлен');
  }

  /// Включает/выключает автоматическое переподключение
  void setAutoReconnect(bool enabled) {
    _autoReconnectEnabled = enabled;
    if (enabled && _isConnected) {
      _startConnectionMonitoring();
    } else {
      _stopConnectionMonitoring();
    }
  }

  /// Получает состояние автоматического переподключения
  bool get autoReconnectEnabled => _autoReconnectEnabled;

  /// Возвращает встроенный обработчик для протокола (делегат к _connectXray/_connectWireGuard и т.д.) или null.
  /// Используется в _connectInternal когда _handlerFactory не задана.
  VpnProtocolHandler? getHandlerFor(VpnProtocol protocol) {
    switch (protocol) {
      case VpnProtocol.xrayVless:
      case VpnProtocol.xrayVlessWsTls:
      case VpnProtocol.xrayVlessGrpcTls:
      case VpnProtocol.xrayVmess:
      case VpnProtocol.xrayReality:
        return _XrayHandlerDelegate(this);
      case VpnProtocol.graniwg:
        return _GraniWGHandlerDelegate(this);
    }
  }
}

/// Делегат: реализация VpnProtocolHandler для Xray, вызывает методы VpnService (логика не дублируется).
class _XrayHandlerDelegate implements VpnProtocolHandler {
  _XrayHandlerDelegate(this._service);
  final VpnService _service;

  @override
  Future<bool> connect(ProtocolConnectParams params) async {
    return _service._connectXray(params.token);
  }

  @override
  Future<bool> applyConfig(String config, VpnProtocol protocol) async {
    return _service._applyXrayConfig(config, protocol);
  }

  @override
  bool isConfigValid(String config, VpnProtocol protocol) {
    return _service._xrayConnectionHandler.isConfigValid(config, protocol);
  }
}

/// Делегат для GraniWG (AmneziaWG). Конфиг получается через POST /vpn/connect.
/// Применение — через amneziawg-go (в разработке для desktop).
class _GraniWGHandlerDelegate implements VpnProtocolHandler {
  _GraniWGHandlerDelegate(this._service);
  final VpnService _service;

  @override
  Future<bool> connect(ProtocolConnectParams params) async {
    return _service._connectGraniWG(params.token);
  }

  @override
  Future<bool> applyConfig(String config, VpnProtocol protocol) async {
    return _service._applyGraniWGConfig(config, protocol);
  }

  @override
  bool isConfigValid(String config, VpnProtocol protocol) {
    if (config.isEmpty) return false;
    final t = config.trim();
    return t.contains('[Interface]') && t.contains('[Peer]');
  }
}

class NoTrafficException implements Exception {
  final String message;
  NoTrafficException(this.message);

  @override
  String toString() => 'NoTrafficException: $message';
}

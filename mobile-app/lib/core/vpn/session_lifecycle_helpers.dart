part of '../../services/vpn_service.dart';

extension VpnServiceSessionLifecycleHelpers on VpnService {
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
    _resumeSyncGuardUntil = DateTime.now().add(
      VpnService._resumeConnectGuardDuration,
    );
    _log(
      'resume_sync_start guard_ms=${VpnService._resumeConnectGuardDuration.inMilliseconds}',
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
  Future<void> prewarmSessionPrepare({
    bool force = false,
    String source = 'unspecified',
  }) async {
    if (_minimalVpnMode) {
      _log(
        'VpnService.prewarmSessionPrepare: disabled in minimal VPN mode, source=$source',
      );
      return;
    }
    if (_connectInProgress ||
        _disconnectInProgress ||
        _isConnectFlowGateActive()) {
      _log(
        'VpnService.prewarmSessionPrepare: skip (connect/disconnect in progress), source=$source',
      );
      return;
    }
    if (!_isXrayProtocol) {
      _log(
        'VpnService.prewarmSessionPrepare: skip (non-xray protocol), source=$source',
      );
      return;
    }
    if (_selectedServer == null) {
      _log(
        'VpnService.prewarmSessionPrepare: skip (selectedServer=null), source=$source',
      );
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
        'VpnService.prewarmSessionPrepare: skip (no token/device), source=$source',
      );
      return;
    }

    final warmKey =
        '${_selectedServer!.id}:${_selectedProtocol.apiValue}:$currentDeviceId';
    final now = DateTime.now();
    if (!force &&
        _lastSessionPreparePrewarmKey == warmKey &&
        _lastSessionPreparePrewarmAt != null &&
        now.difference(_lastSessionPreparePrewarmAt!) <
            VpnService._sessionPreparePrewarmCooldown) {
      _log(
        'VpnService.prewarmSessionPrepare: cooldown hit key=$warmKey source=$source',
      );
      return;
    }

    final inFlight = _sessionPreparePrewarmInFlight;
    if (inFlight != null) {
      _log(
        'VpnService.prewarmSessionPrepare: join in-flight source=$source key=$warmKey',
      );
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
    _notifyListenersFromHelper();
  }

  /// Колбэк нативного туннеля: не выставляем [VpnConnectionState.connected] до [ _connectStageOnSuccess].
  void _onNativeVpnLinkChanged(bool nativeUp) {
    if (!nativeUp) {
      if (_currentState == VpnConnectionState.connected) {
        _stopTrafficStatsMonitoring();
        _applyTransition(VpnConnectionState.disconnected);
      } else {
        _notifyListenersFromHelper();
      }
      return;
    }
    _notifyListenersFromHelper();
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

  /// После refresh access token: сверка Dart↔native и мягкий /vpn/status (не рвём туннель).
  void _onAuthAccessTokenRefreshed() {
    _log(
      'VpnService: access token refreshed — sync native + server if connected',
    );
    if (!_legacyVpnRuntimeObserverEnabled) {
      _log(
        'VpnService._onAuthAccessTokenRefreshed: legacy runtime observer disabled; '
        'SimpleVpnController owns tunnel state',
      );
      return;
    }
    Future<void>(() async {
      try {
        if (_ignoreNetworkChangeUntil != null &&
            DateTime.now().isBefore(_ignoreNetworkChangeUntil!)) {
          _log(
            'VpnService._onAuthAccessTokenRefreshed: skip (grace period after resume)',
          );
          return;
        }
        await syncConnectionStateWithNative();
        if (_deviceId == null || !_isConnected) return;
        final nativeUp = await NativeVpnService.getNativeConnectionStatus();
        if (nativeUp != true) {
          _log(
            'VpnService._onAuthAccessTokenRefreshed: native VPN не подтверждён — skip /vpn/status',
          );
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
    _notifyListenersFromHelper();
  }

  Future<void> _initialize() async {
    try {
      await _loadDeviceId();
      await _refreshXrayAvailability();

      // The active product shell restores the tunnel through
      // SimpleVpnController. The legacy service must not become a second state
      // owner during cold start/resume (especially on Xiaomi/HyperOS).
      if (_legacyVpnRuntimeObserverEnabled) {
        await _restoreConnectionStateFromNative();
      }

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
            _logger.debug(
              'Лимит устройств при регистрации (холодный старт): $e',
            );
            _authService.setPendingDeviceLimit(e);
          } catch (e) {
            _logger.debug(
              'Ошибка регистрации устройства при инициализации: $e',
            );
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
        'Инициализация завершена, загружено серверов: ${_servers.length}',
      );
    } catch (e, stackTrace) {
      _logger.error(
        'Ошибка инициализации VPN сервиса',
        'VpnService',
        e,
        stackTrace,
      );
      // Продолжаем работу, серверы можно загрузить позже
    } finally {
      if (_legacyVpnRuntimeObserverEnabled) {
        _listenNativeVpnState();
      }
    }
  }
}

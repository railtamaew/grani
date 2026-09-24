part of '../../services/vpn_service.dart';

extension VpnServiceConnectPipelineHelpers on VpnService {
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

  /// Обновляет прогресс подключения
  void _updateProgress(ConnectionProgress progress) {
    _connectionProgress = progress;
    _notifyListenersFromHelper();
    _logger.debug(
        'Прогресс подключения: ${progress.percent}% - ${progress.message}');
  }

  void _setConnectionFlowType(ConnectionFlowType type) {
    if (_connectionFlowType == type) return;
    _connectionFlowType = type;
    _log('VpnService.connect: flow_type = ${type.name}');
    _notifyListenersFromHelper();
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
    if (VpnService._diagnosticAllowReconnectFromCache &&
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
    if (VpnService._skipSyncConnectionStateOnConnect) {
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

  bool _isAlreadyConnected400Message(String? message) {
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
        'protocol': 'graniwg',
        if (Platform.isAndroid)
          'client_capabilities': SimpleVpnApi.awg31Capability,
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
        if (Platform.isAndroid &&
            response.data['profile_version'] !=
                SimpleVpnApi.awg31ProfileVersion) {
          throw StateError(
            'Backend returned an incompatible GRANIwg profile: '
            '${response.data['profile_version'] ?? 'missing'}',
          );
        }
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
        _notifyListenersFromHelper();
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
    _notifyListenersFromHelper();
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

  Future<bool> _runConnectAttempts() async {
    return _ConnectAttemptExecutor(this).run();
  }
}

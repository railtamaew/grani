part of '../../services/vpn_service.dart';

extension VpnServiceProtocolAdapterHelpers on VpnService {
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
        _notifyListenersFromHelper();
        throw Exception(message);
      }
      if (!_xrayAvailable) {
        await _refreshXrayAvailability();
        if (!_xrayAvailable) {
          const message =
              'Xray недоступен на этом устройстве. Проверьте сборку приложения.';
          _setError(message);
          _notifyListenersFromHelper();
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
      final cached = VpnService._diagnosticAllowReconnectFromCache
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
            _notifyListenersFromHelper();
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
        _notifyListenersFromHelper();
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

  /// Применение GraniWG/AmneziaWG через native MethodChannel.
  ///
  /// Android uses the embedded amneziawg-go backend. Windows delegates to the
  /// native C++ channel. Apple platforms use a Network Extension Packet Tunnel.
  Future<bool> _applyGraniWGConfig(String config, VpnProtocol protocol) async {
    if (Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows) {
      final ok = await NativeVpnService.connectAmneziaWg(
        config,
        connectionSessionId: _connectionSessionId,
        source: Platform.isWindows
            ? 'desktop_windows_amneziawg'
            : (Platform.isIOS || Platform.isMacOS)
                ? 'apple_packet_tunnel_amneziawg'
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

  /// Disconnect embedded/native AmneziaWG runner.
  Future<void> _disconnectGraniWG() async {
    if (!Platform.isAndroid &&
        !Platform.isIOS &&
        !Platform.isMacOS &&
        !Platform.isWindows) {
      return;
    }
    await NativeVpnService.disconnectAmneziaWg(
      reason: 'user',
      source: Platform.isWindows
          ? 'desktop_windows_amneziawg'
          : (Platform.isIOS || Platform.isMacOS)
              ? 'apple_packet_tunnel_amneziawg'
              : 'legacy_ui_amneziawg',
      connectionSessionId: _connectionSessionId,
    );
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

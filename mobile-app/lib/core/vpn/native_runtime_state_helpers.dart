part of '../../services/vpn_service.dart';

/// Native VPN EventChannel state, traffic snapshots, and Dart UI sync helpers for [VpnService].
extension VpnNativeRuntimeStateHelpers on VpnService {
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

  bool? _boolFromNativeVpnEvent(Map<dynamic, dynamic> event, String key) {
    if (!event.containsKey(key)) return null;
    final v = event[key];
    if (v is bool) return v;
    if (v is num) return v != 0;
    final normalized = v?.toString().toLowerCase();
    if (normalized == 'true' || normalized == '1') return true;
    if (normalized == 'false' || normalized == '0') return false;
    return null;
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
      _notifyListenersFromHelper();
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
    final networkType = event['network_type']?.toString();
    final underlyingNetworkType = event['underlying_network_type']?.toString();
    final underlyingNetworkAvailable =
        _boolFromNativeVpnEvent(event, 'underlying_network_available');
    final internetWithoutVpnOk =
        _boolFromNativeVpnEvent(event, 'internet_without_vpn_ok');
    final underlyingInternetOk =
        _boolFromNativeVpnEvent(event, 'underlying_internet_ok');
    final underlyingProbeRttMs = event.containsKey('underlying_probe_rtt_ms')
        ? _intFromNativeVpnEvent(event, 'underlying_probe_rtt_ms')
        : null;
    final underlyingProbeHttpStatus =
        event.containsKey('underlying_probe_http_status')
            ? _intFromNativeVpnEvent(event, 'underlying_probe_http_status')
            : null;
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
      networkType: networkType,
      underlyingNetworkType: underlyingNetworkType,
      underlyingNetworkAvailable: underlyingNetworkAvailable,
      internetWithoutVpnOk: internetWithoutVpnOk,
      underlyingInternetOk: underlyingInternetOk,
      underlyingProbeUrl: event['underlying_probe_url']?.toString(),
      underlyingProbeRttMs: underlyingProbeRttMs,
      underlyingProbeHttpStatus: underlyingProbeHttpStatus,
      underlyingProbeError: event['underlying_probe_error']?.toString(),
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
        if (networkType != null && networkType.isNotEmpty)
          'network_type': networkType,
        if (underlyingNetworkType != null && underlyingNetworkType.isNotEmpty)
          'underlying_network_type': underlyingNetworkType,
        if (underlyingNetworkAvailable != null)
          'underlying_network_available': underlyingNetworkAvailable,
        if (internetWithoutVpnOk != null)
          'internet_without_vpn_ok': internetWithoutVpnOk,
        if (underlyingInternetOk != null)
          'underlying_internet_ok': underlyingInternetOk,
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
            _postConnectFailedProbeCount >=
                VpnService._postConnectMinFailedProbeCount)) {
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
    final runtimeStatus =
        details['runtime_status']?.toString().trim().toLowerCase();
    final runtimeSessionId = details['runtime_session_id']?.toString().trim();
    final effectiveSessionId = _connectionSessionId ??
        ((runtimeSessionId != null && runtimeSessionId.isNotEmpty)
            ? runtimeSessionId
            : null);
    final isRuntimeError =
        eventName == 'runtime_fail' || runtimeStatus == 'error';

    if (isRuntimeError) {
      _connectionLogger.logConnectionError(
        deviceId: did,
        protocol: _selectedProtocol.apiValue,
        errorMessage:
            (event['runtime_fail_reason'] ?? event['reason'] ?? 'runtime_fail')
                .toString(),
        errorCode: eventName == 'runtime_fail'
            ? 'runtime_fail'
            : 'native_runtime_error',
        clientId: _clientId,
        serverId: serverId,
        errorDetails: details,
        connectionSessionId: effectiveSessionId,
        trigger: _connectionTrigger,
      );
    } else {
      final stage = runtimeStatus != null && runtimeStatus.isNotEmpty
          ? 'runtime_$runtimeStatus'
          : 'native_$eventName';
      _connectionLogger.logConnectionStage(
        deviceId: did,
        protocol: _selectedProtocol.apiValue,
        clientId: _clientId,
        serverId: serverId,
        stage: stage,
        extraDetails: details,
        connectionSessionId: effectiveSessionId,
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

  /// Логика бывшего 10s-polling: обрыв туннеля при включённом auto-reconnect.
  Future<void> _handleNativeDownForReconnect() async {
    _log(
        'VpnService: нативный слой сообщил disconnect — переподключение (event-driven)');
    _applyTransition(VpnConnectionState.disconnected);
    _stopTrafficStatsMonitoring();

    if (_reconnectionAttempts < VpnService._maxReconnectionAttempts) {
      _reconnectionAttempts++;
      _log(
        'VpnService: Попытка переподключения $_reconnectionAttempts/${VpnService._maxReconnectionAttempts}',
      );
      await Future.delayed(VpnService._reconnectionDelay);
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
        _notifyListenersFromHelper();
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
        _notifyListenersFromHelper();
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
        _notifyListenersFromHelper();
      }
      _log(
        'VpnService.syncConnectionStateWithNative: ui_state_after=${_currentState.name}',
      );
    } catch (e) {
      _log('VpnService.syncConnectionStateWithNative: Ошибка (игнорируем): $e');
    }
  }
}

part of '../../services/vpn_service.dart';

extension _VpnDisconnectStateHelpers on VpnService {
  int? _connectionDurationForDisconnectEnd() {
    if (_connectionStartTime == null) return null;
    return DateTime.now().difference(_connectionStartTime!).inMilliseconds;
  }

  void _logDisconnectConnectionEnd(int? connectionDurationMs) {
    if (_deviceId == null) return;
    try {
      _connectionLogger.logConnectionEnd(
        deviceId: _deviceId!,
        protocol: _selectedProtocol.apiValue,
        clientId: _clientId,
        serverId: _selectedServer != null ? int.tryParse(_selectedServer!.id) : null,
        connectionDurationMs: connectionDurationMs,
        bytesSent: _totalBytesSent,
        bytesReceived: _totalBytesReceived,
        connectionSessionId: _connectionSessionId,
        trigger: _connectionTrigger,
      );
    } catch (logError) {
      _log('VpnService.disconnect: Ошибка логирования: $logError');
    }
  }

  Future<void> _finalizeDisconnectSuccess() async {
    // API отключения — строго fire-and-forget: UI и локальный stop не ждут сеть.
    // Расхождение с сервером закрывается отдельной sync-логикой при следующем запуске/резюме.
    // (remoteDisconnect уже запущен выше, если был token/deviceId)

    // Сброс сессионного флага — следующий connect выполнит _syncConnectionState
    _connectionStateSyncDoneThisSession = false;
    _logDisconnectConnectionEnd(_connectionDurationForDisconnectEnd());

    _applyTransition(VpnConnectionState.disconnected);
    _isPaused = false;
    _connectionStartTime = null;
    _currentIpAddress = null;
    _clientId = null;
    if (!VpnService._diagnosticAllowReconnectFromCache) {
      await _clearConfigCache();
    }
    if (_reconnectAfterNetworkChange) {
      _reconnectAfterNetworkChange = false;
      _log(
          'VpnService: [reconnect] disconnect завершён, запланирован connect() через ${AppConfig.reconnectAfterNetworkChangeDelay.inMilliseconds} мс');
      Future.delayed(AppConfig.reconnectAfterNetworkChangeDelay, () {
        _connectTriggeredByNetworkChange = true;
        _lastReconnectConnectStartedAt = DateTime.now();
        connect();
      });
    }
    _lastDisconnectCompletedAt = DateTime.now();
    _lastTunnelConnectedAt = null;
    _connectionSessionId = null;
    _cachedEffectiveOutbounds = null;
    _lastRuntimeContract = null;
    _lastRuntimeCorrelationId = null;
    _connectionTrigger = null;
    _connectionLogger.setVpnTransitioning(false);
    _uiConnectIntent = VpnUiConnectIntent.none;
  }

  void _finalizeDisconnectError(Object error) {
    _log('Ошибка отключения VPN: $error');
    _applyTransition(VpnConnectionState.idle);
    _lastTunnelConnectedAt = null;
    _connectionSessionId = null;
    _cachedEffectiveOutbounds = null;
    _lastRuntimeContract = null;
    _lastRuntimeCorrelationId = null;
    _connectionTrigger = null;
    _connectionLogger.setVpnTransitioning(false);
    _uiConnectIntent = VpnUiConnectIntent.none;
  }

  Future<void> _awaitConnectCompletionBeforeDisconnect() async {
    // Ждём завершения connect, если идёт подключение
    // (макс. disconnectWaitConnectMaxAttempts * disconnectWaitConnectStep)
    int waitAttempts = 0;
    while (_connectInProgress &&
        waitAttempts < AppConfig.disconnectWaitConnectMaxAttempts) {
      await Future.delayed(AppConfig.disconnectWaitConnectStep);
      waitAttempts++;
    }
    if (_connectInProgress) {
      _log(
          'VpnService.disconnect: ⚠️ Ожидание завершения connect истекло, продолжаем отключение');
    }
  }

  Future<void> _prepareDisconnectUiTransition() async {
    _disconnectInProgress = true;
    AppConfig.vpnTunnelConnectedAt = null;
    _lastControlSource = VpnUiControlSource.app;
    _uiConnectIntent = VpnUiConnectIntent.disconnect;
    _connectionLogger.setVpnTransitioning(true);
    _applyTransition(VpnConnectionState.disconnecting);
    _isPaused = false;
    _stopTrafficStatsMonitoring();
    _stopConnectionMonitoring();
    _stopNetworkChangeListener();
    _notifyListenersFromHelper();

    // Короткая пауза для отрисовки «Отключение...» (без длительного ожидания API)
    const frameDelayMs = 50;
    if (VpnService.debugBypassFrameDelay) {
      await Future.delayed(const Duration(milliseconds: frameDelayMs));
    } else {
      await Future<void>(() {
        final c = Completer<void>();
        SchedulerBinding.instance.addPostFrameCallback((_) {
          Future.delayed(
              const Duration(milliseconds: frameDelayMs), () => c.complete());
        });
        return c.future;
      });
    }
  }
}

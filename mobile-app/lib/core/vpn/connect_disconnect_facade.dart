part of '../../services/vpn_service.dart';

/// Второй одновременный вызов [connect] не запускает параллельный пайплайн — ждёт тот же [Future] ([_connectFutureGate]).
extension VpnConnectDisconnectFacade on VpnService {
  Future<bool> connect({bool startTrialTimer = true}) async {
    final inflight = _connectFutureGate;
    if (inflight != null) {
      _log('VpnService.connect: ожидание уже запущенного подключения');
      return inflight;
    }
    final f = _executeConnect(startTrialTimer: startTrialTimer);
    _connectFutureGate = f;
    try {
      return await f;
    } finally {
      _connectFutureGate = null;
    }
  }

  Future<bool> _executeConnect({bool startTrialTimer = true}) async {
    if (VpnService._diagnosticManualConnectOnly &&
        _connectTriggeredByNetworkChange) {
      _log(
        'VpnService.connect: diagnostic_manual_only=true, '
        'network-change auto reconnect blocked',
      );
      _connectTriggeredByNetworkChange = false;
      return false;
    }
    if (!_connectTriggeredByNetworkChange) {
      final lastManualTapAt = _lastManualConnectTapAt;
      if (lastManualTapAt != null) {
        final elapsed = DateTime.now().difference(lastManualTapAt);
        if (elapsed < VpnService._diagnosticSingleTapCooldown) {
          final waitSec =
              ((VpnService._diagnosticSingleTapCooldown.inMilliseconds -
                          elapsed.inMilliseconds) /
                      1000)
                  .ceil();
          _lastConnectionErrorMessage =
              'Подождите $waitSec секунд перед повторной попыткой';
          _log(
            'VpnService.connect: single-tap diagnostic cooldown active '
            'wait_s=$waitSec',
          );
          return false;
        }
      }
      _lastManualConnectTapAt = DateTime.now();
    }

    final lastFinishedAt = _lastConnectFinishedAt;
    if (lastFinishedAt != null) {
      final elapsed = DateTime.now().difference(lastFinishedAt);
      if (elapsed < VpnService._minDelayBetweenConnectAttempts) {
        final waitMs =
            VpnService._minDelayBetweenConnectAttempts.inMilliseconds -
                elapsed.inMilliseconds;
        if (waitMs > 0) {
          _log(
            'VpnService.connect: cooldown before new connect ${waitMs}ms '
            '(prevent overlap with previous session cleanup)',
          );
          await Future<void>.delayed(Duration(milliseconds: waitMs));
        }
      }
    }

    _diagnosticConnectStartAt = DateTime.now();
    _connectionAttemptStartedAt = _diagnosticConnectStartAt;
    _connectionFlowType = ConnectionFlowType.unknown;
    _diagnosticReconnectFromCache = false;
    _cachedEffectiveOutbounds = null;
    _lastRuntimeContract = null;
    _lastRuntimeCorrelationId = null;
    _log('VpnService.connect: ========== НАЧАЛО ПОДКЛЮЧЕНИЯ ==========');
    _log(
        'VpnService.connect: _selectedServer = ${_selectedServer?.id}, _selectedProtocol = ${_selectedProtocol.name}, _deviceId = $_deviceId');
    _log('VpnService.connect: ui_state_before=${_currentState.name}');
    _logConnectSessionStage(
      'connect_pipeline_start',
      extra: <String, Object?>{
        'trigger_network_change': _connectTriggeredByNetworkChange,
      },
    );
    if ((_currentState == VpnConnectionState.idle ||
            _currentState == VpnConnectionState.error) &&
        _hasActiveProxyTunneling()) {
      _lastConnectionErrorMessage = null;
      _uiConnectIntent = VpnUiConnectIntent.none;
      _applyTransition(VpnConnectionState.connected);
      _log(
        'VpnService.connect: live tunnel detected (proxy active), skip duplicate connect',
      );
      _logConnectSessionStage(
        'connect_pipeline_skip_live_tunnel',
        result: 'already_active',
        extra: <String, Object?>{
          'reason': 'proxy_tunneling_detected',
        },
      );
      return true;
    }

    final initialGuard = VpnOperationGuards.evaluateConnect(
      isConnected: _isConnected,
      isConnecting: _isConnecting,
      isResumeSyncGuardActive: isResumeSyncGuardActive,
      isDisconnectInProgress: false,
      isVpnStatusSyncInFlight: false,
      hasPendingDeviceLimit: false,
    );
    if (!initialGuard.isAllowed) {
      if (initialGuard.code == 'already_connected_or_connecting') {
        _log(
            'VpnService.connect: ❌ БЛОКИРОВКА - Уже подключено или идет подключение');
      } else if (initialGuard.code == 'resume_sync_guard') {
        _log(
          'tap_while_resuming guard_active=true ui_state=${_currentState.name}',
        );
      }
      _lastConnectionErrorMessage ??= initialGuard.message;
      return false;
    }
    if (await _syncConnectedFromNativePrecheck()) return true;
    final postNativeGuard = VpnOperationGuards.evaluateConnect(
      isConnected: false,
      isConnecting: false,
      isResumeSyncGuardActive: false,
      isDisconnectInProgress: _disconnectInProgress,
      isVpnStatusSyncInFlight: _vpnStatusSyncInFlight,
      hasPendingDeviceLimit: _authService.hasPendingDeviceLimit,
      pendingDeviceLimitMessage: _authService.pendingDeviceLimitMessage,
    );
    if (!postNativeGuard.isAllowed) {
      if (postNativeGuard.code == 'disconnect_in_progress') {
        _log('VpnService.connect: ❌ БЛОКИРОВКА - Выполняется отключение');
      } else if (postNativeGuard.code == 'status_sync_in_flight') {
        final age = vpnStatusSyncInFlightAgeMs;
        _log(
          'VpnService.connect: ❌ БЛОКИРОВКА - еще выполняется /vpn/status sync '
          'elapsed_ms=${age ?? -1}',
        );
      } else if (postNativeGuard.code == 'pending_device_limit') {
        _log('VpnService.connect: блок — лимит устройств (pending)');
      }
      _lastConnectionErrorMessage ??= postNativeGuard.message;
      return false;
    }
    if (!_selectedProtocol.isImplemented) {
      throw Exception(
          'Выбранный протокол не реализован: ${_selectedProtocol.name}');
    }
    await _authService.ensureNetworkReady();

    await Future<void>.delayed(AppConfig.controlPlaneSettleBeforeConnect);

    _prepareConnectPreflight(startTrialTimer: startTrialTimer);
    try {
      await _prepareConnectStageExecution();

      await _awaitBootstrapForConnect();

      final result = await _runConnectAttempts();
      _logConnectSessionStage(
        'connect_pipeline_finish',
        result: result ? 'success' : 'failed',
        extra: <String, Object?>{
          if (!result) 'fail_code': _lastConnectFailCode ?? '-',
          if (!result) 'fail_stage': _lastConnectFailStage ?? '-',
        },
      );
      return result;
    } finally {
      _lastConnectFinishedAt = DateTime.now();
      _logConnectSessionStage(
        'connect_pipeline_finally',
        extra: <String, Object?>{
          'connect_in_progress': _connectInProgress,
          'ui_state_after': _currentState.name,
        },
      );
      _connectInProgress = false;
      if (_connectionSessionId != null) {
        _cancelledConnectionSessions.remove(_connectionSessionId);
      }
      _connectionLogger.setVpnTransitioning(false);
      if (_currentState == VpnConnectionState.idle ||
          _currentState == VpnConnectionState.disconnected ||
          _currentState == VpnConnectionState.error) {
        _uiConnectIntent = VpnUiConnectIntent.none;
      }
    }
  }

  Future<bool> disconnect({
    String reason = VpnDisconnectReason.user,
    String source = 'unspecified',
  }) async {
    if (!_isConnected && !_isConnecting) return false;
    String initiator = 'user_or_ui';
    if (reason == VpnDisconnectReason.verifyFailed) {
      initiator = 'verify_failed';
    } else if (reason == VpnDisconnectReason.networkChangeReconnect) {
      initiator = 'network_change';
    } else if (reason == VpnDisconnectReason.authLost) {
      initiator = 'auth_lost';
    } else if (reason == VpnDisconnectReason.protocolSwitch) {
      initiator = 'protocol_switch';
    } else if (reason == VpnDisconnectReason.serverSwitch) {
      initiator = 'server_switch';
    }
    final inBackground = VpnOrchestrationRuntime.instance.isInBackground;
    final isAllowedServiceReason = <String>{
      VpnDisconnectReason.authLost,
      VpnDisconnectReason.protocolSwitch,
      VpnDisconnectReason.serverSwitch,
      VpnDisconnectReason.networkChangeReconnect,
      'access_expired',
      'subscription_expired',
      'subscription_revoked',
      'trial_ended',
      'logout',
      'device_limit',
      'device_revoked',
    }.contains(reason);
    _log(
      'VpnService.disconnect: reason=$reason initiator=$initiator '
      'source=$source app_in_background=$inBackground '
      'session=${_connectionSessionId ?? "-"} state=$_currentState '
      'connect_in_progress=$_connectInProgress',
    );
    final sinceConnected = _lastTunnelConnectedAt == null
        ? null
        : DateTime.now().difference(_lastTunnelConnectedAt!);
    final disconnectGuard = VpnOperationGuards.evaluateDisconnect(
      isUserReason: reason == VpnDisconnectReason.user,
      isAllowedServiceReason: isAllowedServiceReason,
      isInBackground: inBackground,
      source: source,
      connectInProgress: _connectInProgress,
      sinceConnected: sinceConnected,
      debounceWindow: VpnService._userDisconnectDebounceAfterConnect,
    );
    if (!disconnectGuard.isAllowed &&
        disconnectGuard.code == 'unsupported_disconnect_reason') {
      _log(
        'VpnService.disconnect: blocked reason=$reason source=$source '
        'guard=unsupported_disconnect_reason',
      );
      return false;
    }
    if (!disconnectGuard.isAllowed &&
        disconnectGuard.code == 'background_non_explicit_user_action') {
      _log(
        'VpnService.disconnect: blocked reason=$reason source=$source '
        'guard=background_non_explicit_user_action',
      );
      return false;
    }
    if (!disconnectGuard.isAllowed &&
        disconnectGuard.code == 'connect_in_progress') {
      _log(
        'VpnService.disconnect: debounced reason=$reason '
        'initiator=$initiator guard=connect_in_progress',
      );
      return false;
    }
    if (!disconnectGuard.isAllowed &&
        disconnectGuard.code == 'post_connect_window' &&
        sinceConnected != null) {
      _log(
        'VpnService.disconnect: debounced reason=$reason '
        'initiator=$initiator guard=post_connect_window '
        'elapsed_ms=${sinceConnected.inMilliseconds} '
        'window_ms=${VpnService._userDisconnectDebounceAfterConnect.inMilliseconds}',
      );
      return false;
    }
    _cancelSessionPrepareFlights(
      reason: 'disconnect:$reason',
      markCurrentSessionCancelled: true,
    );
    await _awaitConnectCompletionBeforeDisconnect();
    await _prepareDisconnectUiTransition();

    try {
      return await _runDisconnectPipeline(reason: reason, source: source);
    } finally {
      _disconnectInProgress = false;
    }
  }
}

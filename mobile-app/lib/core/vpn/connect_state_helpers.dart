part of '../../services/vpn_service.dart';

class _ConnectStateHelpers {
  static void prepareConnectPreflight(
    VpnService s, {
    required bool startTrialTimer,
  }) {
    s._connectInProgress = true;
    s._lastControlSource = VpnUiControlSource.app;
    s._connectStartTrialTimer = startTrialTimer;
    s._connectionLogger.setVpnTransitioning(true);

    final triggerByNetworkChange = s._connectTriggeredByNetworkChange;
    if (triggerByNetworkChange) {
      s._log('VpnService.connect: [reconnect] старт (после смены сети)');
      s._connectTriggeredByNetworkChange = false;
    }

    s._connectionSessionId =
        '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(0xFFFF).toRadixString(16)}';
    s._lastConnectFailCode = null;
    s._lastConnectFailStage = null;
    s._lastConnectFailReason = null;
    s._pendingApplyConfigRevision = null;
    s._pendingApplyPhase = null;
    s._connectedWithAckDelay = false;
    s._applyAckBackgroundInFlight = false;
    s._lastTunnelConnectedAt = null;
    s._cancelledConnectionSessions.remove(s._connectionSessionId);
    // Новый connect должен отменять любые «хвосты» старых prepare-запросов (prewarm/старый retry).
    s._cancelSessionPrepareFlights(
      reason: 'new_connect',
      markCurrentSessionCancelled: false,
    );
    s._connectionTrigger =
        triggerByNetworkChange ? 'reconnect_after_network_change' : 'first_connect';
    s._uiConnectIntent = triggerByNetworkChange
        ? VpnUiConnectIntent.reconnect
        : VpnUiConnectIntent.connect;
  }

  static Future<void> awaitDelayAfterDisconnectIfNeeded(VpnService s) async {
    // Пауза после недавнего disconnect — избегаем гонки tun2socks (initialization before done)
    if (s._lastDisconnectCompletedAt == null) return;
    final elapsed = DateTime.now().difference(s._lastDisconnectCompletedAt!);
    if (elapsed < VpnService._minDelayAfterDisconnect) {
      final waitMs = VpnService._minDelayAfterDisconnect.inMilliseconds - elapsed.inMilliseconds;
      if (waitMs > 0) {
        s._log('VpnService.connect: Пауза ${waitMs}ms после disconnect (tun2socks)');
        await Future.delayed(Duration(milliseconds: waitMs));
      }
    }
    s._lastDisconnectCompletedAt = null;
  }

  static Future<bool> syncConnectedFromNativePrecheck(VpnService s) async {
    try {
      bool? nativeConnected;
      for (var attempt = 0; attempt < 3; attempt++) {
        nativeConnected = await NativeVpnService.getNativeConnectionStatus();
        if (nativeConnected != null) break;
        if (attempt < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
      }
      s._log('native_status source=connect_precheck connected=$nativeConnected');
      if (nativeConnected != true) return false;

      s._lastControlSource = VpnUiControlSource.quickTileOrSystem;
      s._uiConnectIntent = VpnUiConnectIntent.none;
      s._applyTransition(VpnConnectionState.connected);
      s._connectionStartTime = DateTime.now();
      s._startTrafficStatsMonitoring();
      s._reconnectionAttempts = 0;
      s._saveLastConnectedSelection();
      s._lastConnectionErrorMessage = null;
      s._notifyListenersFromHelper();
      s._log(
        'VpnService.connect: already_connected_via_native_sync ui_state_after=${s._currentState.name}',
      );
      return true;
    } catch (e) {
      s._log('VpnService.connect: native precheck error: $e');
      return false;
    }
  }

  static Future<void> awaitBootstrapForConnect(VpnService s) async {
    // Не обнулять сообщение до успешного bootstrap: иначе при throw из waitForBootstrap
    // (в т.ч. мок без stub) наружу уходит исключение с пустым lastConnectionErrorMessage.
    try {
      await s._authService
          .waitForBootstrapForVpnConnect(maxWait: const Duration(seconds: 6));
    } catch (e, stackTrace) {
      s._lastConnectionErrorMessage = s._errorHandler.userMessageForConnectionError(e);
      if (s._lastConnectionErrorMessage == null ||
          s._lastConnectionErrorMessage!.trim().isEmpty) {
        s._lastConnectionErrorMessage = e.toString();
      }
      s._log('VpnService.connect: waitForBootstrapForVpnConnect: $e');
      s._log('VpnService.connect: waitForBootstrap stack: $stackTrace');
      rethrow;
    }
    s._lastConnectionErrorMessage = null;
  }

  static Future<void> prepareConnectStageExecution(VpnService s) async {
    if (s._connectionTrigger == 'reconnect_after_network_change' &&
        s._deviceId != null) {
      s._connectionLogger.logConnectionStage(
        deviceId: s._deviceId!,
        protocol: s._selectedProtocol.apiValue,
        stage: 'reconnect_start',
        durationMs: 0,
        clientId: s._clientId,
        serverId: s._selectedServer != null ? int.tryParse(s._selectedServer!.id) : null,
        connectionSessionId: s._connectionSessionId,
        trigger: s._connectionTrigger,
      );
    }
    await awaitDelayAfterDisconnectIfNeeded(s);
    s._applyTransition(VpnConnectionState.connecting);
    s._connectionProgress = null;
  }

  static void handleConnectAttemptTimeout(VpnService s, Object error) {
    if (error is! TimeoutException) return;
    final timeoutMsg = (error.message ?? '').toString();
    final timeoutStage = timeoutMsg.startsWith('vpn_connect_timeout stage=')
        ? timeoutMsg.replaceFirst('vpn_connect_timeout stage=', '')
        : null;
    if (timeoutStage != null && timeoutStage.isNotEmpty) {
      s._log('VpnService.connect: connect_timeout_stage=$timeoutStage');
    }
    // Future.timeout не отменяет underlying async-цепочку;
    // явно отменяем session/prepare и помечаем текущую сессию как stale.
    s._cancelSessionPrepareFlights(
      reason: 'connect_timeout',
      markCurrentSessionCancelled: true,
    );
  }

  static void logConnectAttemptErrorTelemetry(
    VpnService s,
    Object error,
    StackTrace stackTrace,
    ConnectAttemptContext? ctx,
    String protocolString,
  ) {
    if (s._deviceId == null) return;
    final stageDurationMs = ctx?.stageStopwatch.elapsedMilliseconds ?? 0;
    try {
      final failCode = s._lastConnectFailCode;
      s._connectionLogger.logConnectionError(
        deviceId: s._deviceId!,
        protocol: protocolString,
        errorMessage: error.toString(),
        errorCode: failCode ??
            (error is DioException ? error.response?.statusCode.toString() : null),
        clientId: s._clientId,
        serverId: s._selectedServer != null ? int.tryParse(s._selectedServer!.id) : null,
        errorDetails: _buildConnectErrorDetails(
          error: error,
          stackTrace: stackTrace,
          ctx: ctx,
          stageDurationMs: stageDurationMs,
        ),
        connectionSessionId: s._connectionSessionId,
        trigger: s._connectionTrigger,
      );
    } catch (logError) {
      s._log('VpnService.connect: Ошибка логирования: $logError');
    }
  }

  static void setLastConnectErrorFrom(VpnService s, Object error) {
    s._lastConnectionErrorMessage = _resolveUserFacingConnectError(s, error);
  }

  static void applyConnectFailureState(
    VpnService s, {
    required Object error,
    required int connectionDurationMs,
    required PerfLogger perfLogger,
    required int attemptUsed,
    required String protocolString,
    String? stage,
    bool rethrowError = false,
  }) {
    setLastConnectErrorFrom(s, error);
    s._logConnectionTimingSummary(connectionDurationMs, result: 'error');
    s._connectionProgress = null;
    s._applyTransition(VpnConnectionState.idle);
    perfLogger.record('vpn_connect', connectionDurationMs, details: {
      'result': 'error',
      'attempt': attemptUsed,
      'protocol': protocolString,
      if (stage != null) 'stage': stage,
      if (s._lastConnectFailCode != null) 'fail_code': s._lastConnectFailCode,
      'error': error.runtimeType.toString(),
    });
    unawaited(s._connectionLogger.flushDiagnosticsOnConnectFail());
    if (rethrowError) {
      throw error;
    }
  }

  static void logDioConnectError(VpnService s, DioException error) {
    s._log('VpnService.connect: DioException - type: ${error.type}, message: ${error.message}');
    s._log(
        'VpnService.connect: DioException - response: ${error.response?.data}, statusCode: ${error.response?.statusCode}');
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout) {
      s._log('VpnService.connect: ПРОБЛЕМА - таймаут подключения к серверу');
    } else if (error.type == DioExceptionType.connectionError) {
      s._log(
          'VpnService.connect: ПРОБЛЕМА - ошибка подключения к серверу (сеть недоступна?)');
    } else if (error.response != null) {
      s._log(
          'VpnService.connect: ПРОБЛЕМА - сервер вернул ошибку: ${error.response?.statusCode} - ${error.response?.data}');
    }
  }

  static Map<String, dynamic> _buildConnectErrorDetails({
    required Object error,
    required StackTrace stackTrace,
    required ConnectAttemptContext? ctx,
    required int stageDurationMs,
  }) {
    return {
      if (ctx?.currentStage != null) 'stage': ctx!.currentStage,
      'stage_duration_ms': stageDurationMs,
      if (ctx?.networkType != null) 'network_type': ctx!.networkType,
      'error_type': error.runtimeType.toString(),
      'stack_trace': stackTrace.toString(),
    };
  }

  static String _resolveUserFacingConnectError(VpnService s, Object error) {
    final msg = s._errorHandler.userMessageForConnectionError(error);
    if (msg.trim().isNotEmpty) {
      return msg;
    }
    return error.toString();
  }
}

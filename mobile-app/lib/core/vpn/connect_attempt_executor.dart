part of '../../services/vpn_service.dart';

class _ConnectAttemptExecutor {
  _ConnectAttemptExecutor(this._s);

  final VpnService _s;
  static const int _maxRetries = 2;
  static const Duration _retryDelay = Duration(milliseconds: 450);

  Future<bool> run() async {
    final perfLogger = PerfLogger();
    perfLogger.start('vpn_connect');
    int attemptUsed = 0;
    ConnectAttemptContext? ctx;
    final pipelineSessionId = _s._connectionSessionId;

    for (int attempt = 1; attempt <= _maxRetries; attempt++) {
      attemptUsed = attempt;
      try {
        _ensurePipelineSessionActive(
          expectedSessionId: pipelineSessionId,
          stage: 'attempt_start',
          attempt: attempt,
        );
        _s._logConnectSessionStage(
          'attempt_start',
          extra: <String, Object?>{
            'attempt': attempt,
          },
        );
        final attemptCtx = await _runSingleAttempt(attempt: attempt);
        ctx = attemptCtx;
        _s._logConnectSessionStage(
          'attempt_success',
          result: 'ok',
          extra: <String, Object?>{
            'attempt': attempt,
          },
        );
        perfLogger.stop('vpn_connect', details: _buildSuccessPerfDetails(attemptCtx, attemptUsed));
        return true;
      } catch (e, stackTrace) {
        _logAttemptFailure(e, stackTrace, ctx);
        _s._vpnConfig = null;
        final protocolString = _s._selectedProtocol.apiValue;
        final connectionDurationMs = ctx?.connectionStopwatch.elapsedMilliseconds ?? 0;

        if (_isCriticalError(e)) {
          _s._applyConnectFailureState(
            error: e,
            connectionDurationMs: connectionDurationMs,
            perfLogger: perfLogger,
            attemptUsed: attemptUsed,
            protocolString: protocolString,
            rethrowError: true,
          );
        }

        if (attempt < _maxRetries && _s._shouldRetry(e)) {
          _s._log(
              'VpnService.connect: Повторяем попытку через ${_retryDelay.inMilliseconds} мс...');
          _s._logConnectSessionStage(
            'attempt_retry_scheduled',
            extra: <String, Object?>{
              'attempt': attempt,
            },
          );
          continue;
        }

        _s._applyConnectFailureState(
          error: e,
          connectionDurationMs: connectionDurationMs,
          perfLogger: perfLogger,
          attemptUsed: attemptUsed,
          protocolString: protocolString,
          stage: ctx?.currentStage,
        );
        return false;
      }
    }

    // Defensive fallback; main loop already returns on success/final failure.
    final fallbackError = Exception('Не удалось подключиться после нескольких попыток');
    final protocolString = _s._selectedProtocol.apiValue;
    final connectionDurationMs = ctx?.connectionStopwatch.elapsedMilliseconds ?? 0;
    _s._applyConnectFailureState(
      error: fallbackError,
      connectionDurationMs: connectionDurationMs,
      perfLogger: perfLogger,
      attemptUsed: attemptUsed,
      protocolString: protocolString,
      stage: ctx?.currentStage,
    );
    return false;
  }

  Future<ConnectAttemptContext> _runSingleAttempt({required int attempt}) async {
    _s._lastConnectionTimingMs.clear();
    final expectedSessionId = _s._connectionSessionId;
    if (attempt > 1) {
      _s._log('VpnService.connect: Попытка подключения $attempt/$_maxRetries');
      await Future.delayed(_retryDelay);
    }

    final ctx = ConnectAttemptContext();
    final stageWall = Stopwatch()..start();
    _ensurePipelineSessionActive(
      expectedSessionId: expectedSessionId,
      stage: 'before_prerequisites',
      attempt: attempt,
    );
    final prerequisitesStartMs = stageWall.elapsedMilliseconds;
    late final String token;
    try {
      token = await _s._connectStep1Prerequisites(ctx).timeout(
        VpnOrchestrationSpec.connectingPrerequisitesWallClock,
        onTimeout: () =>
            throw TimeoutException('vpn_connect_timeout stage=prerequisites'),
      );
    } catch (e) {
      _logStageFailure(
        attempt: attempt,
        stage: 'prerequisites',
        error: e,
        ctx: ctx,
        elapsedMs: stageWall.elapsedMilliseconds - prerequisitesStartMs,
      );
      rethrow;
    }
    _s._logConnectSessionStage(
      'stage_elapsed',
      extra: <String, Object?>{
        'stage_name': 'prerequisites',
        'attempt': attempt,
        'elapsed_ms': stageWall.elapsedMilliseconds - prerequisitesStartMs,
      },
    );
    _ensurePipelineSessionActive(
      expectedSessionId: expectedSessionId,
      stage: 'after_prerequisites',
      attempt: attempt,
    );
    final getConfigStartMs = stageWall.elapsedMilliseconds;
    try {
      await _s._connectStep2GetConfig(ctx, token).timeout(
        VpnOrchestrationSpec.connectingGetConfigWallClock,
        onTimeout: () =>
            throw TimeoutException('vpn_connect_timeout stage=get_config'),
      );
    } catch (e) {
      _logStageFailure(
        attempt: attempt,
        stage: 'get_config',
        error: e,
        ctx: ctx,
        elapsedMs: stageWall.elapsedMilliseconds - getConfigStartMs,
      );
      rethrow;
    }
    _s._logConnectSessionStage(
      'stage_elapsed',
      extra: <String, Object?>{
        'stage_name': 'get_config',
        'attempt': attempt,
        'elapsed_ms': stageWall.elapsedMilliseconds - getConfigStartMs,
      },
    );
    _ensurePipelineSessionActive(
      expectedSessionId: expectedSessionId,
      stage: 'after_get_config',
      attempt: attempt,
    );
    final applyVerifyStartMs = stageWall.elapsedMilliseconds;
    try {
      await _s._connectStep3ApplyAndVerify(ctx, token, attempt).timeout(
        VpnOrchestrationSpec.connectingApplyVerifyWallClock,
        onTimeout: () {
          final stage = ctx.currentStage ?? 'unknown';
          throw TimeoutException('vpn_connect_timeout stage=$stage');
        },
      );
    } catch (e) {
      _logStageFailure(
        attempt: attempt,
        stage: 'apply_verify',
        error: e,
        ctx: ctx,
        elapsedMs: stageWall.elapsedMilliseconds - applyVerifyStartMs,
      );
      rethrow;
    }
    _s._logConnectSessionStage(
      'stage_elapsed',
      extra: <String, Object?>{
        'stage_name': 'apply_verify',
        'attempt': attempt,
        'elapsed_ms': stageWall.elapsedMilliseconds - applyVerifyStartMs,
      },
    );
    _ensurePipelineSessionActive(
      expectedSessionId: expectedSessionId,
      stage: 'after_apply_verify',
      attempt: attempt,
    );
    return ctx;
  }

  void _ensurePipelineSessionActive({
    required String? expectedSessionId,
    required String stage,
    required int attempt,
  }) {
    if (!_s._isConnectionSessionActive(expectedSessionId)) {
      _s._logConnectSessionStage(
        'session_guard_block',
        result: 'stale',
        extra: <String, Object?>{
          'expected_session': expectedSessionId ?? 'null',
          'actual_session': _s._connectionSessionId ?? 'null',
          'attempt': attempt,
          'guard_stage': stage,
        },
      );
      throw Exception('stale_connect_session stage=$stage attempt=$attempt');
    }
  }

  Map<String, Object?> _buildSuccessPerfDetails(ConnectAttemptContext ctx, int attemptUsed) {
    final details = <String, Object?>{
      'result': 'success',
      'attempt': attemptUsed,
      'protocol': _s._selectedProtocol.apiValue,
      'duration_ms': ctx.connectionStopwatch.elapsedMilliseconds,
      'tap_to_connected_ms': ctx.connectionStopwatch.elapsedMilliseconds,
    };
    if (ctx.networkType != null) details['network_type'] = ctx.networkType;
    final engineInitMs = _s._lastConnectionTimingMs['engine_init_ms'];
    if (engineInitMs != null) details['engine_init_ms'] = engineInitMs;
    return details;
  }

  void _logAttemptFailure(Object e, StackTrace stackTrace, ConnectAttemptContext? ctx) {
    final failCode = _classifyFailCode(e, ctx?.currentStage);
    _s._lastConnectFailCode = failCode;
    _s._lastConnectFailStage = ctx?.currentStage ?? _inferTimeoutStage(e) ?? 'unknown';
    _s._lastConnectFailReason = e.toString();
    _s._logConnectSessionStage(
      'attempt_error',
      result: 'failed',
      extra: <String, Object?>{
        'fail_code': failCode,
        'fail_stage': _s._lastConnectFailStage ?? '-',
        'error_type': e.runtimeType.toString(),
      },
    );
    _s._log('VpnService.connect: ОШИБКА подключения VPN: $e');
    _s._log('VpnService.connect: Тип ошибки: ${e.runtimeType}');
    _s._log('VpnService.connect: Stack trace: $stackTrace');
    _s._handleConnectAttemptTimeout(e);
    _s._logConnectAttemptErrorTelemetry(
      e,
      stackTrace,
      ctx,
      _s._selectedProtocol.apiValue,
    );
    if (e is DioException) {
      _s._logDioConnectError(e);
      return;
    }
    if (e is Exception) {
      _s._log('VpnService.connect: Неизвестная ошибка типа ${e.runtimeType}: ${e.toString()}');
      return;
    }
    _s._log('VpnService.connect: Неизвестная ошибка типа ${e.runtimeType}: $e');
  }

  bool _isCriticalError(Object e) {
    if (e is VpnException || e is VpnPermissionException) return true;
    if (e is! Exception) return false;
    final msg = e.toString();
    return msg.contains('авторизац') || msg.contains('Требуется повторная');
  }

  void _logStageFailure({
    required int attempt,
    required String stage,
    required Object error,
    required ConnectAttemptContext ctx,
    required int elapsedMs,
  }) {
    final failCode = _classifyFailCode(error, ctx.currentStage ?? stage);
    _s._lastConnectFailCode = failCode;
    _s._lastConnectFailStage = ctx.currentStage ?? stage;
    _s._lastConnectFailReason = error.toString();
    _s._logConnectSessionStage(
      'stage_error',
      result: 'failed',
      extra: <String, Object?>{
        'attempt': attempt,
        'stage_name': stage,
        'ctx_stage': ctx.currentStage ?? '-',
        'elapsed_ms': elapsedMs,
        'fail_code': failCode,
        'error_type': error.runtimeType.toString(),
      },
    );
  }

  String _classifyFailCode(Object error, String? stage) {
    final stageNorm = (stage ?? _inferTimeoutStage(error) ?? 'unknown')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    if (error is TimeoutException) {
      return 'connect_fail_stage_${stageNorm}_timeout';
    }
    if (error is DioException) {
      return 'connect_fail_stage_${stageNorm}_dio_${error.type.name}';
    }
    if (error is VpnPermissionException) {
      return 'connect_fail_stage_${stageNorm}_permission_denied';
    }
    if (error is StaleConnectSessionException) {
      return 'connect_fail_stage_${stageNorm}_stale_session';
    }
    return 'connect_fail_stage_${stageNorm}_${error.runtimeType.toString().toLowerCase()}';
  }

  String? _inferTimeoutStage(Object error) {
    if (error is! TimeoutException) return null;
    final message = (error.message ?? '').toString();
    const prefix = 'vpn_connect_timeout stage=';
    if (!message.startsWith(prefix)) return null;
    final stage = message.replaceFirst(prefix, '').trim();
    return stage.isEmpty ? null : stage;
  }
}

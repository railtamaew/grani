import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../config/app_config.dart';
import '../core/api/api_client.dart';
import '../core/api/endpoint_router.dart';
import '../core/api/preferred_route_storage.dart';
import '../core/http/grani_request_id.dart';
import '../core/vpn/control_plane_client.dart';
import '../core/vpn/network_policy_engine.dart';
import '../core/vpn/vpn_orchestration_spec.dart';

/// Сервис для логирования подключений к VPN и отправки логов на сервер
class ConnectionLogger {
  static final ConnectionLogger _instance = ConnectionLogger._internal();
  factory ConnectionLogger() => _instance;
  ConnectionLogger._internal();

  Map<String, dynamic> _authorizedHeaders(String requestId) {
    return {
      'Authorization': 'Bearer $_cachedToken',
      'X-Request-ID': requestId,
    };
  }

  static bool _isRetryableConnectionError(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return true;
    }
    // RST / broken pipe часто приходят как unknown + SocketException.
    if (e.type == DioExceptionType.unknown) {
      final text = '${e.message ?? ""} ${e.error ?? ""}'.toLowerCase();
      return text.contains('connection reset') ||
          text.contains('write failed') ||
          text.contains('connection aborted') ||
          text.contains('broken pipe') ||
          text.contains('socketexception');
    }
    return false;
  }

  static bool _isNoIpv4ResolutionError(DioException e) {
    final text = '${e.message ?? ""} ${e.error ?? ""}'.toLowerCase();
    return text.contains('no ipv4 address') ||
        text.contains('failed host lookup');
  }

  /// Post-connect диагностика и итог strict connectivity: разрешить flush в background
  /// (иначе `logging blocked in background` теряет commit после ухода с экрана).
  static bool _isConnectivityCommitBackdropFlushEntry(Map<String, dynamic> m) {
    final et = m['event_type'] as String?;
    if (et == 'connectivity_probe' || et == 'traffic_first_seen') return true;
    if (et == 'connection_success') return true;
    if (et == 'connection_stage' &&
        (m['message'] as String?) == 'connectivity_commit_passed') {
      return true;
    }
    if (et == 'connection_error' &&
        (m['message'] as String?) == 'connectivity_commit_failed') {
      return true;
    }
    return false;
  }

  /// Критичные datapath-диагностики должны уходить даже во время CONNECT transition.
  static bool _isCriticalDatapathFlushEntry(Map<String, dynamic> m) {
    final et = m['event_type'] as String?;
    final message = (m['message'] as String?) ?? '';
    final errorCode = (m['error_code'] as String?) ?? '';
    if (et == 'support_diagnostic_report') {
      return true;
    }
    if (_isConnectivityCommitBackdropFlushEntry(m)) return true;
    if (et == 'connection_stage' && message == 'datapath_checkpoint') {
      return true;
    }
    if (et == 'connection_stage' &&
        message.startsWith('app_conflict_b_proxy_probe_')) {
      return true;
    }
    if (et == 'connection_stage' &&
        (message == 'connect_pipeline_finish' ||
            message == 'attempt_error' ||
            message == 'stage_error')) {
      return true;
    }
    if (et == 'connection_error' &&
        (errorCode == 'native_runtime_diag' ||
            errorCode == 'runtime_fail' ||
            errorCode == 'runtime_contract_mismatch' ||
            errorCode.startsWith('connect_fail_stage_'))) {
      return true;
    }
    return false;
  }

  /// Максимум возвратов batch в очередь при ошибках (не 404).
  static const int _maxRequeueAttempts = 5;

  /// Меньше событий в одном POST — ниже риск RST на нестабильном канале сразу после CONNECT.
  static const int _maxLogsPerPost = 5;
  static const int _logChunkDelayMs = 350;
  int _requeueCount = 0;

  /// Пока не истечёт — не начинаем новый flush (транспорт 1×; backoff отдельно от периодического таймера).
  DateTime? _flushNotBefore;
  Timer? _backoffFlushTimer;

  void _armLogFlushBackoff(Duration delay) {
    final until = DateTime.now().add(delay);
    if (_flushNotBefore == null || until.isAfter(_flushNotBefore!)) {
      _flushNotBefore = until;
    }
    _backoffFlushTimer?.cancel();
    _backoffFlushTimer = Timer(delay, () {
      _flushNotBefore = null;
      _backoffFlushTimer = null;
      if (_pendingLogs.isNotEmpty && !_isFlushing) {
        unawaited(_flushLogs(force: true));
      }
    });
  }

  void _clearFlushBackoff() {
    _flushNotBefore = null;
    _backoffFlushTimer?.cancel();
    _backoffFlushTimer = null;
  }

  /// Порядок баз для /vpn/logs/send: сначала IP (DNS к CF часто ломается сразу после CONNECT).
  List<String> _orderedLoggingBases() {
    final out = <String>[];
    void push(String? value) {
      if (value == null || value.isEmpty) return;
      if (!out.contains(value)) out.add(value);
    }

    push(AppConfig.apiBaseUrl);
    push(AppConfig.apiVpnServerUrl);
    push(AppConfig.apiVpnServerUrl8443);
    push(AppConfig.apiGranivpnRuViaHuUrl);
    push(AppConfig.apiGranivpnRuViaHuUrlAlt);
    final bootstrap = AppConfig.cachedApiBaseUrls;
    if (bootstrap != null) {
      for (final b in bootstrap) {
        push(b);
      }
    }
    for (final b in AppConfig.apiBaseUrlFallbacks) {
      push(b);
    }
    push(AppConfig.apiDirectIpUrl);
    return out;
  }

  Future<void> _postLogsChunk(
    List<Map<String, dynamic>> chunk,
    String requestId,
  ) async {
    final bases = _orderedLoggingBases();
    final diagnosticsFlush = chunk.any(_isCriticalDatapathFlushEntry);
    Object? lastError;
    for (final base in bases) {
      final fullUrl = '$base/vpn/logs/send';
      try {
        await ControlPlaneClient.instance.execute(
          ControlPlanePlane.logging,
          (dio) => dio.post(
            fullUrl,
            data: {
              'device_id': _cachedDeviceId,
              'logs': chunk,
            },
            options: Options(
              headers: _authorizedHeaders(requestId),
              sendTimeout: AppConfig.logsSendTimeout,
              receiveTimeout: AppConfig.logsSendTimeout,
            ),
          ),
          connectivityDiagnosticsFlush: diagnosticsFlush,
        );
        return;
      } catch (e) {
        lastError = e;
      }
    }
    if (lastError is DioException) throw lastError;
    throw lastError ?? Exception('logs send failed on all bases');
  }

  Future<bool> _trySendViaFallbackBases(
    List<Map<String, dynamic>> logsToSend,
  ) async {
    final bases = _orderedLoggingBases();
    for (final base in bases) {
      final fullUrl = '$base/vpn/logs/send';
      final rid = newGraniRequestId();
      try {
        // Один POST на базу: при частичном фейле чанков на основном пути хвост уже уменьшен;
        // здесь избегаем рассинхрона «сколько ушло» между базами.
        await ControlPlaneClient.instance.execute(
          ControlPlanePlane.logging,
          (dio) => dio.post(
            fullUrl,
            data: {
              'device_id': _cachedDeviceId,
              'logs': logsToSend,
            },
            options: Options(
              headers: _authorizedHeaders(rid),
              sendTimeout: AppConfig.logsSendTimeout,
              receiveTimeout: AppConfig.logsSendTimeout,
            ),
          ),
        );
        debugPrint('ConnectionLogger: ✅ fallback route success base=$base');
        return true;
      } catch (e) {
        debugPrint(
            'ConnectionLogger: fallback route failed base=$base error=$e');
      }
    }
    return false;
  }

  /// Верхняя граница очереди: при переполнении отбрасыем старые записи (защита от RAM при длительных сетевых сбоях).
  static const int _maxPendingLogs = 100;

  final List<Map<String, dynamic>> _pendingLogs = [];
  Timer? _flushTimer;
  bool _isFlushing = false;
  bool _vpnTransitioning = false;

  // Кэш информации об устройстве
  String? _platform;
  String? _osVersion;
  String? _appVersion;

  // Токен и deviceId для отправки логов
  String? _cachedToken;
  String? _cachedDeviceId;

  /// Коллбэк, вызываемый когда ConnectionLogger разрешает новый device_id
  /// (через fingerprint resolve). VpnService подписывается на него,
  /// чтобы обновить свой _deviceId и сохранить в хранилище.
  void Function(String newDeviceId)? onDeviceIdResolved;

  // Ограничение повторов при 404 «Устройство не найдено» (избежание лишней нагрузки)
  static const int _max404Retries = 3;
  static const Duration _404RetryCooldown = Duration(minutes: 5);
  int _consecutive404Count = 0;
  DateTime? _last404At;
  String? _cachedFingerprint;

  /// Инициализация логгера
  Future<void> initialize() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        _platform = 'android';
        _osVersion = 'Android ${androidInfo.version.release}';
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        _platform = 'ios';
        _osVersion = 'iOS ${iosInfo.systemVersion}';
      }

      final packageInfo = await PackageInfo.fromPlatform();
      _appVersion = packageInfo.version;
    } catch (e) {
      debugPrint('ConnectionLogger: Ошибка инициализации: $e');
    }

    // Запускаем периодическую отправку логов (каждые 30 секунд)
    _flushTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _flushLogs();
    });
  }

  /// Логирование события подключения
  void logConnectionStart({
    required String deviceId,
    required String protocol,
    String? clientId,
    int? serverId,
    String? networkType,
    String? connectionSessionId,
    String? trigger,
    String? connectionFlowType,
  }) {
    _addLog(
      deviceId: deviceId,
      eventType: 'connection_start',
      protocol: protocol,
      clientId: clientId,
      serverId: serverId,
      errorDetails: networkType != null ? {'network_type': networkType} : null,
      connectionSessionId: connectionSessionId,
      trigger: trigger,
      connectionFlowType: connectionFlowType,
    );
  }

  /// Логирование этапа подключения/отключения
  void logConnectionStage({
    required String deviceId,
    required String protocol,
    required String stage,
    int? durationMs,
    String? networkType,
    String? clientId,
    int? serverId,
    String? connectionSessionId,
    String? trigger,
    String? apiRouteUsed,
    int? apiRequestMs,
    String? disconnectReason,
    Map<String, dynamic>? extraDetails,
  }) {
    final details = <String, dynamic>{
      'stage': stage,
      if (durationMs != null) 'duration_ms': durationMs,
      if (networkType != null) 'network_type': networkType,
      if (apiRouteUsed != null) 'api_route_used': apiRouteUsed,
      if (apiRequestMs != null) 'api_request_ms': apiRequestMs,
      if (disconnectReason != null) 'disconnect_reason': disconnectReason,
      if (extraDetails != null) ...extraDetails,
    };
    _addLog(
      deviceId: deviceId,
      eventType: 'connection_stage',
      protocol: protocol,
      clientId: clientId,
      serverId: serverId,
      message: stage,
      errorDetails: details,
      connectionSessionId: connectionSessionId,
      trigger: trigger,
    );
  }

  /// Логирование успешного подключения
  void logConnectionSuccess({
    required String deviceId,
    required String protocol,
    String? clientId,
    int? serverId,
    int? connectionDurationMs,
    int? bytesSent,
    int? bytesReceived,
    String? connectionSessionId,
    String? trigger,
    bool? trafficVerified,
    String? connectionFlowType,
  }) {
    _addLog(
      deviceId: deviceId,
      eventType: 'connection_success',
      protocol: protocol,
      clientId: clientId,
      serverId: serverId,
      connectionDurationMs: connectionDurationMs,
      bytesSent: bytesSent,
      bytesReceived: bytesReceived,
      connectionSessionId: connectionSessionId,
      trigger: trigger,
      errorDetails: trafficVerified != null
          ? {'traffic_verified': trafficVerified}
          : null,
      connectionFlowType: connectionFlowType,
    );
  }

  /// Логирование ошибки подключения
  void logConnectionError({
    required String deviceId,
    required String protocol,
    required String errorMessage,
    String? errorCode,
    String? clientId,
    int? serverId,
    Map<String, dynamic>? errorDetails,
    String? connectionSessionId,
    String? trigger,
  }) {
    final details = Map<String, dynamic>.from(errorDetails ?? {});
    if (connectionSessionId != null) {
      details['connection_session_id'] = connectionSessionId;
    }
    if (trigger != null) {
      details['trigger'] = trigger;
    }
    _addLog(
      deviceId: deviceId,
      eventType: 'connection_error',
      protocol: protocol,
      clientId: clientId,
      serverId: serverId,
      message: errorMessage,
      errorCode: errorCode,
      errorDetails: details.isNotEmpty ? details : null,
      connectionSessionId: connectionSessionId,
      trigger: trigger,
    );
  }

  /// Логирование завершения подключения
  void logConnectionEnd({
    required String deviceId,
    required String protocol,
    String? clientId,
    int? serverId,
    int? connectionDurationMs,
    int? bytesSent,
    int? bytesReceived,
    String? connectionSessionId,
    String? trigger,
  }) {
    _addLog(
      deviceId: deviceId,
      eventType: 'connection_end',
      protocol: protocol,
      clientId: clientId,
      serverId: serverId,
      connectionDurationMs: connectionDurationMs,
      bytesSent: bytesSent,
      bytesReceived: bytesReceived,
      connectionSessionId: connectionSessionId,
      trigger: trigger,
    );
  }

  /// Смена сети (WiFi ↔ mobile), перед переподключением
  void logNetworkChange({
    required String deviceId,
    required String networkFrom,
    required String networkTo,
    String? protocol,
    String? clientId,
    int? serverId,
    String? connectionSessionId,
  }) {
    _addLog(
      deviceId: deviceId,
      eventType: 'network_change',
      protocol: protocol,
      clientId: clientId,
      serverId: serverId,
      message: 'network_change',
      errorDetails: {
        'network_from': networkFrom,
        'network_to': networkTo,
        'trigger': 'reconnect_after_network_change',
      },
      connectionSessionId: connectionSessionId,
      trigger: 'reconnect_after_network_change',
    );
  }

  /// Post-connect HTTP checks (VPN-bound [Network] when available). English field names in [error_details].
  void logConnectivityProbe({
    required String deviceId,
    required String protocol,
    required bool vpnTransportBound,
    required bool publicOk,
    required int publicRttMs,
    required int publicHttpStatus,
    String? publicErr,
    String? publicFailureClass,
    String? publicUrlUsed,
    String? publicLabelUsed,
    int? publicProbeAttempts,
    required bool apiOk,
    required int apiRttMs,
    required int apiHttpStatus,
    String? apiErr,
    String? apiFailureClass,
    String? correlationSessionId,
    String? clientId,
    int? serverId,
    String? connectionSessionId,
    String? trigger,
  }) {
    final details = <String, dynamic>{
      'vpn_transport_bound': vpnTransportBound ? 1 : 0,
      'public_ok': publicOk,
      'public_rtt_ms': publicRttMs,
      'public_http_status': publicHttpStatus,
      'api_ok': apiOk,
      'api_rtt_ms': apiRttMs,
      'api_http_status': apiHttpStatus,
      if (correlationSessionId != null && correlationSessionId.isNotEmpty)
        'correlation_session': correlationSessionId,
      if (publicErr != null && publicErr.isNotEmpty) 'public_err': publicErr,
      if (publicFailureClass != null && publicFailureClass.isNotEmpty)
        'public_failure_class': publicFailureClass,
      if (publicUrlUsed != null && publicUrlUsed.isNotEmpty)
        'public_url': publicUrlUsed,
      if (publicLabelUsed != null && publicLabelUsed.isNotEmpty)
        'public_label': publicLabelUsed,
      if (publicProbeAttempts != null)
        'public_probe_attempts': publicProbeAttempts,
      if (apiErr != null && apiErr.isNotEmpty) 'api_err': apiErr,
      if (apiFailureClass != null && apiFailureClass.isNotEmpty)
        'api_failure_class': apiFailureClass,
    };
    _addLog(
      deviceId: deviceId,
      eventType: 'connectivity_probe',
      protocol: protocol,
      clientId: clientId,
      serverId: serverId,
      message: 'connectivity_probe',
      errorDetails: details,
      connectionSessionId: connectionSessionId,
      trigger: trigger,
    );
  }

  /// Первый зафиксированный трафик через туннель (для мониторинга «трафик пошёл»)
  void logTrafficFirstSeen({
    required String deviceId,
    required String protocol,
    int? rxBytes,
    int? txBytes,
    String? clientId,
    int? serverId,
    String? connectionSessionId,
    String? trigger,
  }) {
    _addLog(
      deviceId: deviceId,
      eventType: 'traffic_first_seen',
      protocol: protocol,
      clientId: clientId,
      serverId: serverId,
      errorDetails: {
        if (rxBytes != null) 'rx_bytes': rxBytes,
        if (txBytes != null) 'tx_bytes': txBytes,
      },
      connectionSessionId: connectionSessionId,
      trigger: trigger,
    );
  }

  /// Логирование ошибки протокола
  void logProtocolError({
    required String deviceId,
    required String protocol,
    required String errorMessage,
    String? errorCode,
    String? clientId,
    int? serverId,
    Map<String, dynamic>? errorDetails,
  }) {
    _addLog(
      deviceId: deviceId,
      eventType: 'protocol_error',
      protocol: protocol,
      clientId: clientId,
      serverId: serverId,
      message: errorMessage,
      errorCode: errorCode,
      errorDetails: errorDetails,
    );
  }

  /// Ручной диагностический отчет от пользователя для поддержки.
  Future<void> sendSupportDiagnosticReport({
    required String deviceId,
    required String protocol,
    int? serverId,
    String? clientId,
    String? connectionSessionId,
    required Map<String, dynamic> details,
  }) async {
    _addLog(
      deviceId: deviceId,
      eventType: 'support_diagnostic_report',
      protocol: protocol,
      clientId: clientId,
      serverId: serverId,
      message: 'support_diagnostic_report',
      errorCode: 'GRANI-SUPPORT-DIAGNOSTIC',
      errorDetails: details,
      connectionSessionId: connectionSessionId,
      trigger: 'manual_support_action',
    );
    await _flushLogs(force: true);
  }

  /// Добавление лога в очередь
  void _addLog({
    required String deviceId,
    required String eventType,
    String? protocol,
    String? clientId,
    int? serverId,
    String? message,
    String? errorCode,
    Map<String, dynamic>? errorDetails,
    int? connectionDurationMs,
    int? bytesSent,
    int? bytesReceived,
    String? connectionSessionId,
    String? trigger,
    String? connectionFlowType,
  }) {
    final details = Map<String, dynamic>.from(errorDetails ?? {});
    final route = PreferredRouteStorage.lastSuccessfulRouteForLogging;
    if (route != null) details['api_route_used'] = route;

    final logEntry = {
      'event_type': eventType,
      if (protocol != null) 'protocol': protocol,
      if (clientId != null) 'client_id': clientId,
      if (serverId != null) 'server_id': serverId,
      if (message != null) 'message': message,
      if (errorCode != null) 'error_code': errorCode,
      if (details.isNotEmpty) 'error_details': details,
      if (_platform != null) 'platform': _platform,
      if (_osVersion != null) 'os_version': _osVersion,
      if (_appVersion != null) 'app_version': _appVersion,
      if (connectionDurationMs != null)
        'connection_duration_ms': connectionDurationMs,
      if (bytesSent != null) 'bytes_sent': bytesSent,
      if (bytesReceived != null) 'bytes_received': bytesReceived,
      if (connectionSessionId != null)
        'connection_session_id': connectionSessionId,
      if (trigger != null) 'trigger': trigger,
      if (connectionFlowType != null && connectionFlowType.isNotEmpty)
        'connection_flow_type': connectionFlowType,
    };

    _pendingLogs.add(logEntry);
    while (_pendingLogs.length > _maxPendingLogs) {
      _pendingLogs.removeAt(0);
    }

    // Если накопилось много логов, отправляем немедленно
    if (_pendingLogs.length >= 10) {
      _flushLogs();
    }
  }

  /// Установка токена и deviceId для отправки логов.
  /// [flushImmediately] = false: только установить credentials, не запускать отправку.
  /// Используется в connect flow — flush выполняется после подъёма VPN, иначе запрос
  /// уходит в момент смены маршрутизации (TUN up) и получает Connection reset by peer.
  void setCredentials(String? token, String? deviceId,
      {bool flushImmediately = true}) {
    debugPrint(
        'ConnectionLogger.setCredentials: Установка credentials (token=${token != null && token.isNotEmpty}, deviceId=${deviceId != null && deviceId.isNotEmpty})');
    _cachedToken = token;
    _cachedDeviceId = deviceId;

    if (!flushImmediately) {
      debugPrint(
          'ConnectionLogger.setCredentials: flushImmediately=false, отложенный flush (VPN ещё не поднят)');
      return;
    }

    // Если credentials установлены и есть накопленные логи, отправляем в фоне (не блокируем инициализацию)
    if (token != null &&
        token.isNotEmpty &&
        deviceId != null &&
        deviceId.isNotEmpty &&
        _pendingLogs.isNotEmpty) {
      debugPrint(
          'ConnectionLogger.setCredentials: Есть накопленные логи (${_pendingLogs.length}), отправляем в фоне...');
      unawaited(_flushLogs());
    } else {
      debugPrint(
          'ConnectionLogger.setCredentials: Нет накопленных логов или credentials неполные (pendingLogs=${_pendingLogs.length})');
    }
  }

  /// Устанавливает флаг переходного состояния VPN (connect/disconnect).
  /// Во время перехода периодический flush приостанавливается, т.к. сеть нестабильна.
  void setVpnTransitioning(bool transitioning) {
    _vpnTransitioning = transitioning;
    debugPrint('ConnectionLogger.setVpnTransitioning: $transitioning');
  }

  /// Запланировать отправку накопленных логов. Вызывать после успешного подключения VPN,
  /// когда VPN активен (API идёт через туннель).
  /// Задержка после CONNECT даёт маршрутизации и радиоканалу время стабилизироваться.
  void scheduleFlush() {
    _vpnTransitioning = false;
    if (_cachedToken == null ||
        _cachedToken!.isEmpty ||
        _cachedDeviceId == null ||
        _cachedDeviceId!.isEmpty ||
        _pendingLogs.isEmpty) {
      return;
    }
    debugPrint(
        'ConnectionLogger.scheduleFlush: VPN поднят, отправка ${_pendingLogs.length} логов (задержка 5 сек)');
    Future.delayed(const Duration(seconds: 5), () {
      if (_pendingLogs.isNotEmpty) {
        unawaited(_flushLogs(force: true));
      }
    });
  }

  /// Отложенная отправка (например после [logConnectivityProbe]), не сбрасывает основной 5s flush.
  void scheduleFlushAfter(Duration delay) {
    if (_cachedToken == null ||
        _cachedToken!.isEmpty ||
        _cachedDeviceId == null ||
        _cachedDeviceId!.isEmpty ||
        _pendingLogs.isEmpty) {
      return;
    }
    Future.delayed(delay, () {
      if (_pendingLogs.isNotEmpty) {
        unawaited(_flushLogs(force: true));
      }
    });
  }

  /// После возврата приложения на передний план: догнать очередь логов (в т.ч. только connectivity_probe).
  void flushPendingAfterResumeIfAny() {
    Future.delayed(const Duration(milliseconds: 600), () {
      if (_pendingLogs.isEmpty) return;
      unawaited(_flushLogs(force: true));
    });
  }

  /// Отправка накопленных логов на сервер.
  /// [force] = true пропускает проверку _vpnTransitioning (используется из scheduleFlush).
  /// При пропуске всегда один лог с [skip_reason=...] для парсинга и аналитики.
  Future<void> _flushLogs({bool force = false}) async {
    if (_isFlushing) {
      debugPrint(
          'ConnectionLogger._flushLogs: Пропуск [skip_reason=already_flushing] pendingLogs=${_pendingLogs.length}');
      return;
    }
    if (_pendingLogs.isEmpty) {
      debugPrint(
          'ConnectionLogger._flushLogs: Пропуск [skip_reason=empty_queue]');
      return;
    }
    final criticalDatapathFlush = _pendingLogs.isNotEmpty &&
        _pendingLogs.every(_isCriticalDatapathFlushEntry);
    if (!force && _vpnTransitioning && !criticalDatapathFlush) {
      debugPrint(
          'ConnectionLogger._flushLogs: Пропуск [skip_reason=vpn_transitioning] pendingLogs=${_pendingLogs.length}');
      return;
    }
    final diagnosticsOnly = _pendingLogs.isNotEmpty &&
        _pendingLogs.every(
          (m) => (m['event_type'] as String?) == 'connectivity_probe',
        );
    final commitBackdropFlush = _pendingLogs.isNotEmpty &&
        _pendingLogs.every(_isConnectivityCommitBackdropFlushEntry);
    final hasCriticalDatapathFlush =
        _pendingLogs.any(_isCriticalDatapathFlushEntry);
    final logPolicy = NetworkPolicyEngine.instance.evaluate(
      ControlPlanePlane.logging,
      connectivityDiagnosticsFlush: diagnosticsOnly ||
          commitBackdropFlush ||
          criticalDatapathFlush ||
          hasCriticalDatapathFlush,
    );
    if (!logPolicy.allowed) {
      debugPrint(
        'ConnectionLogger._flushLogs: Пропуск [skip_reason=policy] ${logPolicy.denyReason ?? ""} pendingLogs=${_pendingLogs.length}',
      );
      return;
    }
    if (_cachedToken == null ||
        _cachedToken!.isEmpty ||
        _cachedDeviceId == null ||
        _cachedDeviceId!.isEmpty) {
      debugPrint(
          'ConnectionLogger._flushLogs: Пропуск [skip_reason=no_credentials] pendingLogs=${_pendingLogs.length} token=${_cachedToken != null && _cachedToken!.isNotEmpty} deviceId=${_cachedDeviceId != null && _cachedDeviceId!.isNotEmpty}');
      return;
    }

    final notBefore = _flushNotBefore;
    if (notBefore != null && DateTime.now().isBefore(notBefore)) {
      debugPrint(
          'ConnectionLogger._flushLogs: Пропуск [skip_reason=backoff] until=$notBefore');
      return;
    }

    debugPrint(
        'ConnectionLogger._flushLogs: Начало отправки ${_pendingLogs.length} логов');
    debugPrint('ConnectionLogger._flushLogs: device_id=$_cachedDeviceId');
    final basesOrder = _orderedLoggingBases();
    debugPrint(
      'ConnectionLogger._flushLogs: bases_try_first=${basesOrder.isNotEmpty ? basesOrder.first : "-"} '
      'count=${basesOrder.length}',
    );

    _isFlushing = true;

    // Копируем логи для отправки (объявляем вне try для доступа в catch)
    final logsToSend = List<Map<String, dynamic>>.from(_pendingLogs);
    _pendingLogs.clear();
    var sentCount = 0;

    // Транспорт: серия POST с ограничением размера чанка (ControlPlaneClient, порядок баз IP-first).
    // Повторная постановка неотправленного хвоста — лимит _maxRequeueAttempts и backoff 1s→3s.
    try {
      DioException? lastDioError;
      try {
        while (sentCount < logsToSend.length) {
          final end = min(sentCount + _maxLogsPerPost, logsToSend.length);
          final chunk = logsToSend.sublist(sentCount, end);
          if (sentCount > 0) {
            await Future<void>.delayed(
                const Duration(milliseconds: _logChunkDelayMs));
          }
          final requestId = newGraniRequestId();
          debugPrint(
            'ConnectionLogger._flushLogs: X-Request-ID=$requestId path=/vpn/logs/send chunk=${chunk.length} offset=$sentCount/${logsToSend.length}',
          );
          await _postLogsChunk(chunk, requestId);
          sentCount = end;
        }

        debugPrint(
            'ConnectionLogger._flushLogs: ✅ Логи успешно отправлены: ${logsToSend.length} шт.');
        _consecutive404Count = 0;
        _requeueCount = 0;
        _clearFlushBackoff();
        lastDioError = null;
      } on ControlPlaneDeniedException catch (e) {
        debugPrint('ConnectionLogger._flushLogs: отказ шлюза: $e');
        _pendingLogs.insertAll(0, logsToSend.sublist(sentCount));
        _armLogFlushBackoff(const Duration(seconds: 1));
        lastDioError = null;
      } on DioException catch (e) {
        lastDioError = e;
        if (_isRetryableConnectionError(e)) {
          await PreferredRouteStorage.reportRouteFailure(
            AppConfig.apiBaseUrl,
            path: '/vpn/logs/send',
          );
        }
      }

      if (lastDioError != null) {
        final e = lastDioError;
        debugPrint('ConnectionLogger: ❌ Ошибка отправки логов: $e');
        debugPrint('ConnectionLogger: Тип ошибки: DioException');
        debugPrint(
            'ConnectionLogger: DioException - type: ${e.type}, statusCode: ${e.response?.statusCode}');
        debugPrint(
            'ConnectionLogger: DioException - response: ${e.response?.data}');
        debugPrint(
            'ConnectionLogger: DioException - request: ${e.requestOptions.uri}');

        if (_isNoIpv4ResolutionError(e)) {
          debugPrint(
              'ConnectionLogger: обнаружен DNS A-record сбой, пробуем fallback-маршруты');
          final remainder = logsToSend.sublist(sentCount);
          final sentViaFallback = await _trySendViaFallbackBases(remainder);
          if (sentViaFallback) {
            _consecutive404Count = 0;
            _requeueCount = 0;
            _clearFlushBackoff();
            return;
          }
        }

        if (e.response?.statusCode == 404) {
          final now = DateTime.now();
          if (_last404At != null &&
              now.difference(_last404At!) > _404RetryCooldown) {
            _consecutive404Count = 0;
          }
          _last404At = now;
          _consecutive404Count++;
          if (_consecutive404Count > _max404Retries) {
            debugPrint(
                'ConnectionLogger: ⚠️ 404 повторяется ($_consecutive404Count раз), логи не возвращаются в очередь. device_id=$_cachedDeviceId');
          } else {
            debugPrint(
                'ConnectionLogger: ⚠️ Устройство не найдено на сервере. device_id=$_cachedDeviceId (попытка $_consecutive404Count/$_max404Retries)');
            // Сначала пробуем resolve по fingerprint — получить существующий device_id
            final resolved = await _tryResolveDeviceIdByFingerprint();
            if (resolved) {
              debugPrint(
                  'ConnectionLogger: ✅ device_id разрешён по fingerprint: $_cachedDeviceId');
              _consecutive404Count = 0;
              _pendingLogs.insertAll(0, logsToSend.sublist(sentCount));
            } else {
              // Resolve не помог — пробуем зарегистрировать новое устройство
              try {
                await _registerDeviceRetry();
                debugPrint(
                    'ConnectionLogger: ✅ Устройство зарегистрировано повторно, возвращаем логи в очередь');
                _consecutive404Count = 0;
                _pendingLogs.insertAll(0, logsToSend.sublist(sentCount));
              } catch (regError) {
                debugPrint(
                    'ConnectionLogger: ❌ Не удалось зарегистрировать устройство: $regError');
              }
            }
          }
        } else {
          // Ограничиваем число возвратов в очередь при повторных ошибках (не 404)
          if (_requeueCount < _maxRequeueAttempts) {
            _requeueCount++;
            _pendingLogs.insertAll(0, logsToSend.sublist(sentCount));
            debugPrint(
                'ConnectionLogger: Логи возвращены в очередь для повторной попытки ($_requeueCount/$_maxRequeueAttempts)');
            _armLogFlushBackoff(
              Duration(seconds: _requeueCount == 1 ? 1 : 3),
            );
          } else {
            debugPrint(
                'ConnectionLogger: ⚠️ Достигнут лимит возвратов ($_maxRequeueAttempts), логи не возвращаются в очередь');
          }
        }
      }
    } catch (e) {
      debugPrint('ConnectionLogger: ❌ Неожиданная ошибка отправки логов: $e');
      debugPrint('ConnectionLogger: Тип ошибки: ${e.runtimeType}');
      if (_requeueCount < _maxRequeueAttempts) {
        _requeueCount++;
        _pendingLogs.insertAll(0, logsToSend.sublist(sentCount));
        _armLogFlushBackoff(
          Duration(seconds: _requeueCount == 1 ? 1 : 3),
        );
      }
    } finally {
      _isFlushing = false;
    }
  }

  /// Принудительная отправка всех накопленных логов
  Future<void> flush() async {
    await _flushLogs();
  }

  /// Диагностический flush при падении connect: временно снимает transitioning-gate
  /// и запускает force flush, чтобы не потерять stage/error телеметрию.
  Future<void> flushDiagnosticsOnConnectFail() async {
    final prev = _vpnTransitioning;
    _vpnTransitioning = false;
    try {
      await _flushLogs(force: true);
    } finally {
      _vpnTransitioning = prev;
    }
  }

  /// Пробует разрешить device_id через fingerprint (POST /vpn/device/resolve).
  /// Если устройство найдено — обновляет _cachedDeviceId и уведомляет VpnService.
  Future<bool> _tryResolveDeviceIdByFingerprint() async {
    if (_cachedToken == null || _cachedToken!.isEmpty) return false;

    try {
      final fingerprint = await _getDeviceFingerprint();
      if (fingerprint == null || fingerprint.isEmpty) {
        debugPrint(
            'ConnectionLogger._tryResolveDeviceId: fingerprint недоступен');
        return false;
      }

      debugPrint(
          'ConnectionLogger._tryResolveDeviceId: resolve по fingerprint...');
      final rid = newGraniRequestId();
      final response = await ApiClient().post(
        '/vpn/device/resolve',
        requestKind: RequestKind.vpnControl,
        data: {'fingerprint': fingerprint},
        options: Options(
          headers: _authorizedHeaders(rid),
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      if (response.statusCode == 200 && response.data != null) {
        final resolvedId = response.data['device_id']?.toString();
        if (resolvedId != null && resolvedId.isNotEmpty) {
          debugPrint(
              'ConnectionLogger._tryResolveDeviceId: ✅ resolved device_id=$resolvedId (был: $_cachedDeviceId)');
          _cachedDeviceId = resolvedId;
          onDeviceIdResolved?.call(resolvedId);
          return true;
        }
      }
      debugPrint(
          'ConnectionLogger._tryResolveDeviceId: resolve не вернул device_id');
      return false;
    } catch (e) {
      debugPrint('ConnectionLogger._tryResolveDeviceId: ❌ ошибка resolve: $e');
      return false;
    }
  }

  /// Fingerprint устройства (SHA-256 от androidId/vendorId + bundleId).
  Future<String?> _getDeviceFingerprint() async {
    if (_cachedFingerprint != null && _cachedFingerprint!.isNotEmpty) {
      return _cachedFingerprint;
    }
    try {
      final deviceInfo = DeviceInfoPlugin();
      final packageInfo = await PackageInfo.fromPlatform();
      final bundleId = packageInfo.packageName;
      String? rawId;
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        rawId = androidInfo.id;
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        rawId = iosInfo.identifierForVendor;
      }
      if (rawId == null || rawId.isEmpty) return null;
      final combined = '$rawId#$bundleId';
      final bytes = utf8.encode(combined);
      final digest = sha256.convert(bytes);
      _cachedFingerprint = digest.toString();
      return _cachedFingerprint;
    } catch (e) {
      debugPrint('ConnectionLogger._getDeviceFingerprint: ошибка: $e');
      return null;
    }
  }

  /// Повторная регистрация устройства при 404 ошибке
  Future<void> _registerDeviceRetry() async {
    if (_cachedToken == null ||
        _cachedToken!.isEmpty ||
        _cachedDeviceId == null ||
        _cachedDeviceId!.isEmpty) {
      debugPrint(
          'ConnectionLogger._registerDeviceRetry: Нет credentials для регистрации');
      return;
    }

    try {
      final deviceInfo = DeviceInfoPlugin();
      String platform = 'unknown';
      String deviceName = 'Unknown Device';

      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        platform = 'android';
        deviceName = '${androidInfo.manufacturer} ${androidInfo.model}';
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        platform = 'ios';
        deviceName = '${iosInfo.name} (${iosInfo.model})';
      }

      final fingerprint = await _getDeviceFingerprint();

      debugPrint(
          'ConnectionLogger._registerDeviceRetry: Регистрация устройства device_id=$_cachedDeviceId, name=$deviceName, platform=$platform, hasFingerprint=${fingerprint != null}');

      final data = <String, dynamic>{
        'device_id': _cachedDeviceId,
        'name': deviceName,
        'platform': platform,
      };
      if (fingerprint != null && fingerprint.isNotEmpty) {
        data['fingerprint'] = fingerprint;
      }

      final rid = newGraniRequestId();
      final response = await ApiClient().post(
        '/vpn/device/register',
        requestKind: RequestKind.vpnControl,
        data: data,
        options: Options(
          headers: _authorizedHeaders(rid),
          receiveTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 30),
        ),
      );
      debugPrint(
          'ConnectionLogger._registerDeviceRetry: ✅ Устройство успешно зарегистрировано, statusCode=${response.statusCode}');
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;
      if (statusCode == 409 || statusCode == 200) {
        debugPrint(
            'ConnectionLogger._registerDeviceRetry: ✅ Устройство уже зарегистрировано (statusCode=$statusCode)');
      } else {
        debugPrint(
            'ConnectionLogger._registerDeviceRetry: ❌ Ошибка регистрации устройства: ${e.message}, statusCode=$statusCode');
        debugPrint(
            'ConnectionLogger._registerDeviceRetry: response body: ${e.response?.data}');
        rethrow;
      }
    } catch (e) {
      debugPrint(
          'ConnectionLogger._registerDeviceRetry: ❌ Неожиданная ошибка регистрации устройства: $e');
      rethrow;
    }
  }

  /// Очистка ресурсов
  void dispose() {
    _flushTimer?.cancel();
    _clearFlushBackoff();
    _flushLogs(); // Отправляем оставшиеся логи
  }
}

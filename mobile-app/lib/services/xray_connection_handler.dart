/// Обработчик подключения Xray: получение конфига с API и применение к нативному слою.
///
/// Выделен из VpnService для упрощения архитектуры (Фаза 3 плана xray-only).
/// Содержит логику: fetch config → parse → apply to NativeVpnService.
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../config/app_config.dart';
import '../models/server.dart';
import '../models/vpn_protocol.dart';
import '../core/api/preferred_route_storage.dart';
import '../protocols/xray/xray_protocol.dart';
import 'native_vpn_service.dart';
import '../core/api/api_client.dart';
import '../core/api/network_timeouts.dart';
import '../core/http/grani_request_id.dart';
import '../core/vpn/vpn_log_redaction.dart';

/// Результат получения конфига Xray с API.
class XrayConfigData {
  const XrayConfigData({
    required this.jsonConfig,
    this.requestId,
    this.clientId,
    this.ipAddress,
    this.serverConfigRevision,
    this.applyConfigRevision,
    this.applyConfigSha256,
    this.configEtag,
    this.runtimeContract,
    this.correlationId,
    this.applyPhase,
    this.retryAfterSec,
  });

  final String jsonConfig;
  final String? requestId;
  final String? clientId;
  final String? ipAddress;

  /// Серверный отпечаток конфига (API `config_revision` или аналог).
  final String? serverConfigRevision;

  /// Ревизия фактического apply на ноде (для ACK-gate).
  final String? applyConfigRevision;
  final String? applyConfigSha256;
  final String? configEtag;

  /// Ответ API `runtime_contract` — для fail-fast на Android до запуска VPN.
  final Map<String, dynamic>? runtimeContract;

  /// Корреляция с бэкендом (логи SSH/API).
  final String? correlationId;

  /// Фаза apply из backend (`applied`, `applied_cached`, `await_apply_confirmation`, `failed`).
  final String? applyPhase;
  final int? retryAfterSec;
}

/// Результат применения конфига к нативному слою.
class XrayApplyResult {
  const XrayApplyResult({
    required this.success,
    this.xrayProtocol,
  });

  final bool success;
  final XrayProtocol? xrayProtocol;
}

/// Колбэк для логирования (избегаем зависимости от Logger).
typedef XrayLogCallback = void Function(String message);

/// Контракт для кэша Xray-конфига (serverId+protocol → config+clientId).
abstract class XrayConfigCache {
  Future<
      ({
        String config,
        String? clientId,
        String? serverConfigRevision,
        String? configEtag,
        String? contentSha256,
      })?> get(String serverId, String protocol);

  Future<void> set(
    String serverId,
    String protocol,
    String config, {
    String? clientId,
    String? serverConfigRevision,
    String? configEtag,
  });
}

/// Контракт для принудительного отключения на сервере (при 400 «уже подключено»).
typedef ForceDisconnectOnServer = Future<bool> Function(String token);

/// Проверяет, совпадает ли порт в JSON-конфиге с ожидаемым для протокола.
/// Предотвращает использование устаревших кешей после смены портов на сервере.
/// Ожидаемый порт: [AppConfig.expectedXrayPort] (bootstrap → fallback как в backend constants).
bool _isPortValid(Map<String, dynamic> m, String protocolApiValue) {
  final expected = AppConfig.expectedXrayPort(protocolApiValue);
  if (expected == null) return true;
  final portData = m['port'];
  int? port;
  if (portData is int) {
    port = portData;
  } else if (portData is String) {
    port = int.tryParse(portData);
  }
  if (port == null) return false;
  return port == expected;
}

const String _xrayV2ConnectPath = '/v2/vpn/xray/connect';
const String _xrayLegacyCreateClientPath = '/vpn/xray/create-client';

({Duration connect, Duration send, Duration receive}) _shrinkFirstAttemptTimeout(
  ({Duration connect, Duration send, Duration receive}) t,
) {
  // First connect can be slower on mobile networks and during cold backend path
  // (auth/bootstrap + runtime inbound resolution). 12s creates false transport retries.
  const maxFirstConnect = Duration(seconds: 20);
  const maxFirstReceive = Duration(seconds: 20);
  Duration cap(Duration value, Duration max) => value > max ? max : value;
  return (
    connect: cap(t.connect, maxFirstConnect),
    send: t.send,
    receive: cap(t.receive, maxFirstReceive),
  );
}

/// Извлекает серверный revision/etag из ответа API (если есть).
({String? revision, String? etag}) _revisionAndEtagFromApiResponse(
    dynamic data) {
  if (data is! Map) {
    return (revision: null, etag: null);
  }
  final m = Map<String, dynamic>.from(data);
  String? revision;
  for (final k in ['config_revision', 'revision', 'config_hash']) {
    final v = m[k];
    if (v != null && v.toString().isNotEmpty) {
      revision = v.toString();
      break;
    }
  }
  final ev = m['etag'];
  final etag = ev != null && ev.toString().isNotEmpty ? ev.toString() : null;
  return (revision: revision, etag: etag);
}

/// Валидация конфига для кэша (без создания XrayConnectionHandler).
bool isXrayConfigValidForStorage(String config, String protocolApiValue) {
  if (config.isEmpty) return false;
  try {
    final trimmed = config.trim();
    VpnProtocol p = protocolApiValue == 'xray_vless'
        ? VpnProtocol.xrayVless
        : protocolApiValue == 'xray_vless_ws_tls'
            ? VpnProtocol.xrayVlessWsTls
            : protocolApiValue == 'xray_vless_grpc_tls'
                ? VpnProtocol.xrayVlessGrpcTls
                : protocolApiValue == 'xray_vmess'
                    ? VpnProtocol.xrayVmess
                    : VpnProtocol.xrayReality;
    if (trimmed.startsWith('{')) {
      final m = jsonDecode(trimmed) as Map<String, dynamic>;
      if (!_isPortValid(m, protocolApiValue)) return false;
      if (p == VpnProtocol.xrayReality) {
        return (m['tls'] == 'reality' || m['tls'] == 'tls') &&
            (m['pbk'] != null && (m['pbk'] as String).isNotEmpty) &&
            (m['sni'] != null && (m['sni'] as String).isNotEmpty);
      }
      return m['add'] != null && m['port'] != null && m['id'] != null;
    }
    return trimmed.startsWith('vless://') || trimmed.startsWith('vmess://');
  } catch (_) {
    return false;
  }
}

/// Реализация XrayConfigCache через StorageService (SecureStorage).
class StorageXrayConfigCache implements XrayConfigCache {
  StorageXrayConfigCache(this._storage, this._isConfigValid);

  final dynamic _storage; // StorageService
  /// (config, protocolApiValue) -> bool
  final bool Function(String config, String protocolApiValue) _isConfigValid;

  String _key(String serverId, String protocol) =>
      'xray_config_${serverId}_$protocol';

  static String _sha256Hex(String text) {
    final digest = sha256.convert(utf8.encode(text));
    return digest.toString();
  }

  @override
  Future<
      ({
        String config,
        String? clientId,
        String? serverConfigRevision,
        String? configEtag,
        String? contentSha256,
      })?> get(String serverId, String protocol) async {
    final value = await _storage.getSecureString(_key(serverId, protocol));
    if (value == null || value.isEmpty) return null;
    try {
      if (value.trim().startsWith('{')) {
        final json = jsonDecode(value) as Map<String, dynamic>?;
        if (json == null) return null;
        final config = json['config'] as String?;
        if (config == null ||
            config.isEmpty ||
            !_isConfigValid(config, protocol)) return null;
        return (
          config: config,
          clientId: json['client_id'] as String?,
          serverConfigRevision: json['server_config_revision'] as String?,
          configEtag: json['config_etag'] as String?,
          contentSha256: json['content_sha256'] as String?,
        );
      }
      if (_isConfigValid(value, protocol)) {
        final h = _sha256Hex(value);
        return (
          config: value as String,
          clientId: null,
          serverConfigRevision: null,
          configEtag: null,
          contentSha256: h,
        );
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<void> set(
    String serverId,
    String protocol,
    String config, {
    String? clientId,
    String? serverConfigRevision,
    String? configEtag,
  }) async {
    final key = _key(serverId, protocol);
    final contentSha256 = _sha256Hex(config);
    final envelope = <String, dynamic>{
      'config': config,
      'cached_at_ms': DateTime.now().millisecondsSinceEpoch,
      'cache_v': 2,
      'content_sha256': contentSha256,
    };
    if (clientId != null && clientId.isNotEmpty) {
      envelope['client_id'] = clientId;
    }
    if (serverConfigRevision != null && serverConfigRevision.isNotEmpty) {
      envelope['server_config_revision'] = serverConfigRevision;
    }
    if (configEtag != null && configEtag.isNotEmpty) {
      envelope['config_etag'] = configEtag;
    }
    await _storage.setSecureString(key, jsonEncode(envelope));
  }
}

/// Обработчик подключения Xray. Инкапсулирует fetch config + apply.
class XrayConnectionHandler {
  XrayConnectionHandler({
    required ApiClientInterface apiClient,
    required XrayConfigCache cache,
    required ForceDisconnectOnServer forceDisconnectOnServer,
    XrayLogCallback? log,
  })  : _apiClient = apiClient,
        _cache = cache,
        _forceDisconnectOnServer = forceDisconnectOnServer,
        _log = log ?? _defaultLog;

  final ApiClientInterface _apiClient;
  final XrayConfigCache _cache;
  final ForceDisconnectOnServer _forceDisconnectOnServer;
  final XrayLogCallback _log;
  DateTime? _lastAlreadyConnectedRecoveryAt;

  /// Параллельные вызовы с одним ключом ждут один Future (двойной prepare).
  final Map<String, Future<XrayConfigData>> _inflightPrepareByKey = {};
  final Map<String, CancelToken> _inflightPrepareCancelByKey = {};

  static void _defaultLog(String msg) =>
      debugPrint('XrayConnectionHandler: $msg');

  bool _isBackgroundPrewarmSession(String? connectionSessionId) {
    if (connectionSessionId == null) return false;
    final sid = connectionSessionId.trim();
    if (sid.isEmpty || sid == '-') return false;
    return sid.startsWith('prewarm:');
  }

  void _traceSessionPrepare(String message) {
    _log(message);
    // Дублируем в stdout logcat, чтобы не зависеть от уровня внутреннего Logger.
    debugPrint('session_prepare_trace: $message');
  }

  String _prepareInflightKey(
          Server server, VpnProtocol protocol, String? deviceId) =>
      '${server.id}|${protocol.apiValue}|${deviceId ?? ''}';

  String _baseForRouteHealth(Uri uri) {
    final hostPart =
        '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
    final hasApiPrefix = uri.path.startsWith('/api/');
    return hasApiPrefix ? '$hostPart/api' : hostPart;
  }

  /// Жесткая отмена всех in-flight session/prepare запросов.
  /// Используется при новом connect / timeout, чтобы поздние ответы не попадали в apply.
  void cancelInflightSessionPrepare({String reason = 'cancelled'}) {
    if (_inflightPrepareCancelByKey.isEmpty) return;
    _traceSessionPrepare(
      'session/prepare cancel_all count=${_inflightPrepareCancelByKey.length} reason=$reason',
    );
    for (final entry in _inflightPrepareCancelByKey.entries) {
      final token = entry.value;
      if (!token.isCancelled) {
        token.cancel('session_prepare_cancelled:$reason');
      }
    }
  }

  /// Проверка валидности конфига для протокола.
  /// Включает проверку порта: устаревший кеш с неверным портом считается невалидным.
  bool isConfigValid(String config, VpnProtocol protocol) {
    if (config.isEmpty) return false;
    try {
      final trimmed = config.trim();
      if (trimmed.startsWith('{')) {
        final m = jsonDecode(trimmed) as Map<String, dynamic>;
        if (!_isPortValid(m, protocol.apiValue)) return false;
        if (protocol == VpnProtocol.xrayReality) {
          return (m['tls'] == 'reality' || m['tls'] == 'tls') &&
              (m['pbk'] != null && (m['pbk'] as String).isNotEmpty) &&
              (m['sni'] != null && (m['sni'] as String).isNotEmpty);
        }
        return m['add'] != null && m['port'] != null && m['id'] != null;
      }
      if (trimmed.startsWith('vless://') || trimmed.startsWith('vmess://')) {
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Получить конфиг из кэша (reconnect без API).
  Future<XrayConfigData?> getCachedConfig(
      Server server, VpnProtocol protocol) async {
    final cached = await _cache.get(server.id, protocol.apiValue);
    if (cached == null) return null;
    if (!isConfigValid(cached.config, protocol)) return null;
    return XrayConfigData(
      jsonConfig: cached.config,
      requestId: 'cache',
      clientId: cached.clientId,
      serverConfigRevision: cached.serverConfigRevision,
      applyConfigRevision: cached.serverConfigRevision,
      applyConfigSha256: null,
      configEtag: cached.configEtag,
      applyPhase: 'applied_cached',
      retryAfterSec: 0,
    );
  }

  Future<Response> _postVpnXrayPath(
      String path,
      Map<String, dynamic> data,
      String token,
      ({Duration connect, Duration send, Duration receive}) t,
      String requestId,
      {CancelToken? cancelToken}) {
    return _apiClient.post(
      path,
      data: data,
      cancelToken: cancelToken,
      options: Options(
        headers: {
          'Authorization': 'Bearer $token',
          'X-Request-ID': requestId,
        },
        sendTimeout: t.send,
        receiveTimeout: t.receive,
        extra: {
          // Приоритетный запрос подключения: не ставим в общий backpressure-очередь.
          'grani_skip_api_gate': true,
          'grani_connect_timeout': t.connect,
          'grani_send_timeout': t.send,
          'grani_receive_timeout': t.receive,
          'grani_skip_retry': true,
        },
      ),
    );
  }

  /// Приоритет: v2 xray-connect, затем fallback на legacy контуры.
  Future<Response> _postCreateClientWithTimeoutRetry(
      Map<String, dynamic> data, String token,
      {CancelToken? cancelToken}) async {
    final first = await NetworkTimeouts.xrayCreateClientFirst();
    final firstReqId = newGraniRequestId();
    try {
      return await _postVpnXrayPath(
        _xrayV2ConnectPath,
        data,
        token,
        first,
        firstReqId,
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return await _postVpnXrayPath(
          _xrayLegacyCreateClientPath,
          data,
          token,
          first,
          firstReqId,
          cancelToken: cancelToken,
        );
      }
      if (e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionTimeout) {
        _log('Таймаут xray/create-client, повторная попытка...');
        final retry = await NetworkTimeouts.xrayCreateClientRetry();
        final retryReqId = newGraniRequestId();
        return await _postVpnXrayPath(
          _xrayV2ConnectPath,
          data,
          token,
          retry,
          retryReqId,
          cancelToken: cancelToken,
        );
      }
      rethrow;
    }
  }

  void _logFailedStage({
    required String stage,
    required int attempt,
    String? requestId,
    String? reason,
    String? path,
    Uri? uri,
    int? status,
    int? elapsedMs,
  }) {
    final baseUrl = uri == null
        ? '-'
        : '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
    _traceSessionPrepare(
      'xray_fetch_config_failed_stage '
      'stage=$stage attempt=$attempt request_id=${requestId ?? "-"} '
      'path=${path ?? "-"} base_url=$baseUrl status=${status ?? "-"} '
      'elapsed_ms=${elapsedMs ?? "-"} reason=${reason ?? "-"}',
    );
  }

  /// Запросить конфиг с API (session/prepare или create-client).
  Future<XrayConfigData> fetchConfig({
    required String token,
    required Server server,
    required VpnProtocol protocol,
    String? deviceId,
    String? connectionSessionId,
    bool forceFresh = false,
    bool useSessionPrepare = false,
  }) async {
    final key = _prepareInflightKey(server, protocol, deviceId);
    final existing = _inflightPrepareByKey[key];
    if (existing != null) {
      // Для активного connect (не prewarm) нельзя "прилипать" к старому
      // подвисшему in-flight запросу: отменяем его и поднимаем новый attempt.
      final shouldJoinExisting =
          !forceFresh || _isBackgroundPrewarmSession(connectionSessionId);
      if (shouldJoinExisting) {
        _log('fetchConfig: ожидание уже выполняющегося session/prepare');
        return existing;
      }
      _traceSessionPrepare(
        'session/prepare force_fresh_retry key=$key '
        'connection_session_id=${connectionSessionId ?? "-"}',
      );
      final prevToken = _inflightPrepareCancelByKey[key];
      if (prevToken != null && !prevToken.isCancelled) {
        prevToken.cancel('session_prepare_force_fresh_retry');
      }
    }
    final cancelToken = CancelToken();
    final fut = _fetchConfigFromApi(
      token: token,
      server: server,
      protocol: protocol,
      deviceId: deviceId,
      cancelToken: cancelToken,
      connectionSessionId: connectionSessionId,
      useSessionPrepare: useSessionPrepare,
    );
    _inflightPrepareByKey[key] = fut;
    _inflightPrepareCancelByKey[key] = cancelToken;
    try {
      return await fut;
    } finally {
      final currentFuture = _inflightPrepareByKey[key];
      if (identical(currentFuture, fut)) {
        _inflightPrepareByKey.remove(key);
      }
      final currentToken = _inflightPrepareCancelByKey[key];
      if (identical(currentToken, cancelToken)) {
        _inflightPrepareCancelByKey.remove(key);
      }
    }
  }

  Future<XrayConfigData> _fetchConfigFromApi({
    required String token,
    required Server server,
    required VpnProtocol protocol,
    String? deviceId,
    CancelToken? cancelToken,
    String? connectionSessionId,
    bool useSessionPrepare = false,
  }) async {
    final sw = Stopwatch()..start();
    final data = <String, dynamic>{
      'server_id': int.parse(server.id),
      'protocol': protocol.apiValue,
    };
    final trafficProfile = _trafficProfileForProtocol(protocol);
    if (trafficProfile != null && trafficProfile.isNotEmpty) {
      data['traffic_profile'] = trafficProfile;
    }
    if (deviceId != null && deviceId.isNotEmpty) data['device_id'] = deviceId;
    const hardAttemptTimeout = Duration(seconds: 40);
    String? retryRouteSwitchReason;
    String? prevRequestId;
    bool firstAttemptIngressReached = false;

    for (var attempt = 1; attempt <= 2; attempt++) {
      if (attempt == 2) {
        // Первая попытка могла отмениться по таймеру, пока сервер ещё держит lock и
        // считает create_client — короткая пауза снижает шторм второй POST в тот же lock.
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      }
      final perAttemptSw = Stopwatch()..start();
      final requestId = newGraniRequestId();
      Response? response;
      Timer? hardCancelTimer;
      var actuallySent = false;
      final attemptCancelToken = CancelToken();
      Future<void>? cancelMirrorFuture;
      if (cancelToken != null) {
        if (cancelToken.isCancelled) {
          attemptCancelToken.cancel(
            'session_prepare_parent_cancelled_attempt=$attempt '
            'request_id=$requestId reason=${cancelToken.cancelError?.toString() ?? "-"}',
          );
        } else {
          cancelMirrorFuture = cancelToken.whenCancel.then((_) {
            if (!attemptCancelToken.isCancelled) {
              attemptCancelToken.cancel(
                'session_prepare_parent_cancelled_attempt=$attempt '
                'request_id=$requestId reason=${cancelToken.cancelError?.toString() ?? "-"}',
              );
            }
          });
        }
      }
      try {
        if (attempt > 1 && retryRouteSwitchReason != null) {
          _traceSessionPrepare(
            'session/prepare route_switch_reason=$retryRouteSwitchReason '
            'from_request_id=${prevRequestId ?? "-"} to_request_id=$requestId '
            'first_attempt_ingress_reached=$firstAttemptIngressReached '
            'connection_session_id=${connectionSessionId ?? "-"}',
          );
        }
        const primaryPath = _xrayV2ConnectPath;
        final routeAlias = useSessionPrepare ? 'prepare->v2' : 'v2';
        _traceSessionPrepare(
          'session/prepare start attempt=$attempt/2 request_id=$requestId '
          'route=$primaryPath route_alias=$routeAlias '
          'connection_session_id=${connectionSessionId ?? "-"}',
        );
        _traceSessionPrepare(
          'session/prepare dispatch attempt=$attempt request_id=$requestId '
          'base=auto path=$primaryPath connection_session_id=${connectionSessionId ?? "-"}',
        );
        final first = attempt == 1
            ? (useSessionPrepare
                ? await NetworkTimeouts.xraySessionPrepareFirst()
                : await NetworkTimeouts.xrayCreateClientFirst())
            : (useSessionPrepare
                ? await NetworkTimeouts.xraySessionPrepareRetry()
                : await NetworkTimeouts.xrayCreateClientRetry());
        final tunedTimeouts =
            attempt == 1 ? _shrinkFirstAttemptTimeout(first) : first;
        try {
          hardCancelTimer = Timer(hardAttemptTimeout, () {
            if (!attemptCancelToken.isCancelled) {
              attemptCancelToken.cancel(
                'session_prepare_hard_timeout wall_ms=${hardAttemptTimeout.inMilliseconds} '
                'attempt=$attempt request_id=$requestId',
              );
            }
          });
          actuallySent = true;
          _traceSessionPrepare(
            'session/prepare onwire attempt=$attempt request_id=$requestId '
            'path=$primaryPath',
          );
          response = await _postVpnXrayPath(
            primaryPath,
            data,
            token,
            tunedTimeouts,
            requestId,
            cancelToken: attemptCancelToken,
          );
        } on DioException catch (e) {
          hardCancelTimer?.cancel();
          hardCancelTimer = null;
          if (e.response?.statusCode == 404) {
            _log(
              'xray/v2-connect → 404 attempt=$attempt request_id=$requestId, '
              'fallback -> /vpn/xray/create-client',
            );
            response = await _postVpnXrayPath(
              _xrayLegacyCreateClientPath,
              data,
              token,
              tunedTimeouts,
              requestId,
              cancelToken: attemptCancelToken,
            );
          } else {
            rethrow;
          }
        }
        hardCancelTimer?.cancel();
        hardCancelTimer = null;

        final reqId = response.headers.value('x-request-id') ??
            response.requestOptions.headers['X-Request-ID']?.toString() ??
            requestId;
        _traceSessionPrepare(
          'session/prepare headers_received attempt=$attempt request_id=$reqId '
          'route=${response.requestOptions.path} base_url=${response.requestOptions.uri} '
          'connection_session_id=${connectionSessionId ?? "-"}',
        );
        if (attempt == 1) {
          firstAttemptIngressReached = true;
        }

        final body = response.data;
        if (response.statusCode != 200 ||
            body is! Map ||
            body['success'] != true) {
          _logFailedStage(
            stage: 'post_prepare',
            attempt: attempt,
            requestId: reqId,
            reason: 'unexpected_response_shape_or_status',
            path: response.requestOptions.path,
            uri: response.requestOptions.uri,
            status: response.statusCode,
            elapsedMs: perAttemptSw.elapsedMilliseconds,
          );
          throw Exception(
            (body is Map ? (body['detail'] ?? body['message']) : null) ??
                'Ошибка получения конфига',
          );
        }

        final clientId = body['client_id'] as String?;
        final ipAddress = body['ip_address'] as String?;
        dynamic jsonConfig = body['json_config'];
        Map<String, dynamic>? jsonConfigMap;
        var decodeMs = 0;
        if (jsonConfig is Map) {
          jsonConfigMap = Map<String, dynamic>.from(jsonConfig);
        } else if (jsonConfig is String && jsonConfig.trim().isNotEmpty) {
          final decodeSw = Stopwatch()..start();
          final parsed = jsonDecode(jsonConfig);
          decodeSw.stop();
          decodeMs = decodeSw.elapsedMilliseconds;
          if (parsed is Map) {
            jsonConfigMap = Map<String, dynamic>.from(parsed);
          }
        }
        _traceSessionPrepare(
          'session/prepare body_parsed attempt=$attempt request_id=$reqId '
          'json_decode_ms=$decodeMs has_json_config=${jsonConfigMap != null} '
          'connection_session_id=${connectionSessionId ?? "-"}',
        );
        if (jsonConfigMap == null || jsonConfigMap.isEmpty) {
          _logFailedStage(
            stage: 'parse',
            attempt: attempt,
            requestId: reqId,
            reason: 'json_config_missing_or_empty',
            path: response.requestOptions.path,
            uri: response.requestOptions.uri,
            status: response.statusCode,
            elapsedMs: perAttemptSw.elapsedMilliseconds,
          );
          throw Exception('Сервер не вернул json_config. Попробуйте еще раз.');
        }

        final jsonConfigStr = jsonEncode(jsonConfigMap);
        final revEtag = _revisionAndEtagFromApiResponse(body);
        String? applyRevision;
        final applyRevisionRaw = body['apply_config_revision'];
        if (applyRevisionRaw != null &&
            applyRevisionRaw.toString().isNotEmpty) {
          applyRevision = applyRevisionRaw.toString();
        } else if (body['apply_state'] is Map) {
          final v = (body['apply_state'] as Map)['config_revision'];
          if (v != null && v.toString().isNotEmpty) {
            applyRevision = v.toString();
          }
        }
        String? applySha256;
        final applyShaRaw = body['apply_config_sha256'];
        if (applyShaRaw != null && applyShaRaw.toString().isNotEmpty) {
          applySha256 = applyShaRaw.toString();
        } else if (body['apply_state'] is Map) {
          final v = (body['apply_state'] as Map)['config_sha256'];
          if (v != null && v.toString().isNotEmpty) {
            applySha256 = v.toString();
          }
        }
        try {
          await _cache.set(
            server.id,
            protocol.apiValue,
            jsonConfigStr,
            clientId: clientId,
            serverConfigRevision: applyRevision ?? revEtag.revision,
            configEtag: revEtag.etag,
          );
        } catch (e) {
          _logFailedStage(
            stage: 'post_prepare',
            attempt: attempt,
            requestId: reqId,
            reason: 'cache_set_failed: $e',
            path: response.requestOptions.path,
            uri: response.requestOptions.uri,
            status: response.statusCode,
            elapsedMs: perAttemptSw.elapsedMilliseconds,
          );
          rethrow;
        }
        sw.stop();
        _log(
          'session/prepare ok attempt=$attempt/2 request_id=$reqId '
          'status=${response.statusCode} total_ms=${sw.elapsedMilliseconds}',
        );
        Map<String, dynamic>? runtimeContract;
        final rcRaw = body['runtime_contract'];
        if (rcRaw is Map) {
          runtimeContract = Map<String, dynamic>.from(
            rcRaw.map((k, v) => MapEntry(k.toString(), v)),
          );
        }
        final correlationFromBody = body['correlation_id']?.toString().trim();
        final correlationId =
            (correlationFromBody != null && correlationFromBody.isNotEmpty)
                ? correlationFromBody
                : reqId;
        final phaseRaw = body['phase'];
        final applyPhase = phaseRaw == null ? null : phaseRaw.toString().trim();
        int? retryAfterSec;
        final retryRaw = body['retry_after'];
        if (retryRaw is num) {
          retryAfterSec = retryRaw.toInt();
        } else if (retryRaw is String) {
          retryAfterSec = int.tryParse(retryRaw);
        }
        _traceSessionPrepare(
          'session/prepare runtime_contract keys=${runtimeContract?.keys.join(",") ?? "-"} '
          'has_mismatch=${runtimeContract?["has_mismatch"]} correlation_id=$correlationId '
          'phase=${applyPhase ?? "-"} retry_after=${retryAfterSec ?? "-"}',
        );
        return XrayConfigData(
          jsonConfig: jsonConfigStr,
          requestId: reqId,
          clientId: clientId,
          ipAddress: ipAddress,
          serverConfigRevision: revEtag.revision,
          applyConfigRevision: applyRevision,
          applyConfigSha256: applySha256,
          configEtag: revEtag.etag,
          runtimeContract: runtimeContract,
          correlationId: correlationId,
          applyPhase: (applyPhase != null && applyPhase.isNotEmpty)
              ? applyPhase
              : null,
          retryAfterSec: retryAfterSec,
        );
      } on DioException catch (e) {
        hardCancelTimer?.cancel();
        hardCancelTimer = null;
        final errorReqId = e.response?.headers.value('x-request-id') ??
            e.requestOptions.headers['X-Request-ID']?.toString();
        final reqId = requestId;
        final errMsg = '${e.message ?? ""} ${e.error ?? ""}';
        final hardTimeoutCancel = e.type == DioExceptionType.cancel &&
            errMsg.contains('session_prepare_hard_timeout') &&
            errMsg.contains('request_id=$requestId');
        final staleCancelFromPrevAttempt = e.type == DioExceptionType.cancel &&
            errMsg.contains('session_prepare_hard_timeout') &&
            !errMsg.contains('request_id=$requestId');
        if (staleCancelFromPrevAttempt) {
          _traceSessionPrepare(
            'session/prepare stale_cancel_ignored attempt=$attempt '
            'request_id=$requestId stale_request_id=${errorReqId ?? "-"} '
            'reason=cancel_from_previous_attempt',
          );
          if (attempt < 2) {
            continue;
          }
        }
        if (e.response == null) {
          _traceSessionPrepare(
            'session/prepare headers_received attempt=$attempt request_id=$reqId '
            'route=${e.requestOptions.path} base_url=${e.requestOptions.uri} no_response=true',
          );
          _traceSessionPrepare(
            'session/prepare body_parsed attempt=$attempt request_id=$reqId '
            'json_decode_ms=0 has_json_config=false skipped=true reason=no_response',
          );
        }
        if (e.response?.statusCode == 400) {
          final errorData = e.response?.data;
          _log(
            'VPN config POST 400 path=${e.requestOptions.path} body=${VpnLogRedaction.redactForLog(errorData)}',
          );
          final message = errorData is Map
              ? ((errorData['error'] is Map
                      ? (errorData['error']['message'] as String?)
                      : errorData['message'] as String?) ??
                  errorData['detail'] as String? ??
                  '')
              : '';
          if (message.toLowerCase().contains('уже подключено') ||
              message.toLowerCase().contains('already connected')) {
            if (_isBackgroundPrewarmSession(connectionSessionId)) {
              _traceSessionPrepare(
                'session/prepare prewarm_skip_already_connected attempt=$attempt '
                'request_id=$reqId connection_session_id=${connectionSessionId ?? "-"}',
              );
              final cached = await getCachedConfig(server, protocol);
              if (cached != null) {
                return cached;
              }
              throw Exception('session_prepare_prewarm_skip_already_connected');
            }
            final now = DateTime.now();
            final lastRecoveryAt = _lastAlreadyConnectedRecoveryAt;
            if (lastRecoveryAt != null &&
                now.difference(lastRecoveryAt) < const Duration(seconds: 12)) {
              _log(
                'Повторный "already connected" сразу после recovery — '
                'прерываем цикл disconnect/reconnect и отдаём ошибку выше',
              );
              rethrow;
            }
            _lastAlreadyConnectedRecoveryAt = now;
            _log('Устройство уже подключено, отключаем на сервере...');
            final ok = await _forceDisconnectOnServer(token);
            await Future.delayed(Duration(milliseconds: ok ? 500 : 1000));
            return _fetchConfigFromApi(
              token: token,
              server: server,
              protocol: protocol,
              deviceId: deviceId,
              connectionSessionId: connectionSessionId,
            );
          }
        }

        final isTransportIssue = e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.sendTimeout ||
            hardTimeoutCancel;
        final failReason =
            hardTimeoutCancel ? 'hard_timeout_wall_ms' : e.type.toString();
        _logFailedStage(
          stage: 'transport',
          attempt: attempt,
          requestId: reqId,
          reason: failReason,
          path: e.requestOptions.path,
          uri: e.requestOptions.uri,
          status: e.response?.statusCode,
          elapsedMs: perAttemptSw.elapsedMilliseconds,
        );
        if (hardTimeoutCancel) {
          retryRouteSwitchReason = 'attempt1_timeout';
          prevRequestId = reqId;
          try {
            final failedBase = _baseForRouteHealth(e.requestOptions.uri);
            await PreferredRouteStorage.reportRouteFailure(
              failedBase,
              path: _xrayV2ConnectPath,
            );
            await PreferredRouteStorage.recordNetworkClassFailure(failedBase);
          } catch (_) {}
        }
        if (attempt == 1 && isTransportIssue && !hardTimeoutCancel) {
          retryRouteSwitchReason = 'attempt1_transport_error';
          prevRequestId = reqId;
          try {
            final failedBase = _baseForRouteHealth(e.requestOptions.uri);
            await PreferredRouteStorage.reportRouteFailure(
              failedBase,
              path: _xrayV2ConnectPath,
            );
            await PreferredRouteStorage.recordNetworkClassFailure(failedBase);
          } catch (_) {}
        }
        if (isTransportIssue && attempt < 2) {
          _log(
            'session/prepare controlled_retry reason=${e.type} '
            'attempt=$attempt/2 next_attempt=${attempt + 1} '
            'request_id=$reqId',
          );
          continue;
        }
        sw.stop();
        _log(
          'session/prepare fail request_id=$reqId '
          'type=${e.type} status=${e.response?.statusCode} '
          'attempt=$attempt actually_sent=$actuallySent '
          'total_ms=${sw.elapsedMilliseconds}',
        );
        _traceSessionPrepare(
          'session/prepare final_error attempt=$attempt request_id=$reqId '
          'actually_sent=$actuallySent type=${e.type} '
          'error_request_id=${errorReqId ?? "-"} '
          'status=${e.response?.statusCode ?? "-"}',
        );
        rethrow;
      } on FormatException catch (e) {
        if (response == null) {
          _traceSessionPrepare(
            'session/prepare headers_received attempt=$attempt request_id=$requestId '
            'route=- base_url=- no_response=true',
          );
          _traceSessionPrepare(
            'session/prepare body_parsed attempt=$attempt request_id=$requestId '
            'json_decode_ms=0 has_json_config=false skipped=true reason=format_exception_without_response',
          );
        }
        _logFailedStage(
          stage: 'parse',
          attempt: attempt,
          requestId: requestId,
          reason: 'format_exception: $e',
          path: response?.requestOptions.path,
          uri: response?.requestOptions.uri,
          status: response?.statusCode,
          elapsedMs: perAttemptSw.elapsedMilliseconds,
        );
        if (attempt < 2) continue;
        _traceSessionPrepare(
          'session/prepare final_error attempt=$attempt request_id=$requestId '
          'actually_sent=$actuallySent type=format_exception',
        );
        rethrow;
      } catch (e) {
        if (response == null) {
          _traceSessionPrepare(
            'session/prepare headers_received attempt=$attempt request_id=$requestId '
            'route=- base_url=- no_response=true',
          );
          _traceSessionPrepare(
            'session/prepare body_parsed attempt=$attempt request_id=$requestId '
            'json_decode_ms=0 has_json_config=false skipped=true reason=post_prepare_without_response',
          );
        }
        _logFailedStage(
          stage: 'post_prepare',
          attempt: attempt,
          requestId: requestId,
          reason: e.toString(),
          path: response?.requestOptions.path,
          uri: response?.requestOptions.uri,
          status: response?.statusCode,
          elapsedMs: perAttemptSw.elapsedMilliseconds,
        );
        if (attempt < 2) continue;
        _traceSessionPrepare(
          'session/prepare final_error attempt=$attempt request_id=$requestId '
          'actually_sent=$actuallySent type=post_prepare',
        );
        rethrow;
      } finally {
        hardCancelTimer?.cancel();
        if (cancelMirrorFuture != null) {
          unawaited(cancelMirrorFuture.catchError((_) {}));
        }
      }
    }
    throw Exception('xray config fetch exhausted controlled retries');
  }

  String? _trafficProfileForProtocol(VpnProtocol protocol) {
    // Keep heavy traffic away from baseline vless@4443.
    if (protocol == VpnProtocol.xrayVless) {
      return 'throughput';
    }
    return null;
  }

  /// Применить конфиг к нативному VPN (XrayProtocol + NativeVpnService).
  Future<XrayApplyResult> applyConfig({
    required String configJson,
    required VpnProtocol protocol,
    int? mtu,
    String? connectionSessionId,
    String? nativeSource,
    Map<String, dynamic>? runtimeContract,
    String? correlationId,
    required void Function(bool connected) onConnectStateChanged,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const XrayApplyResult(success: false);
    }
    final xrayProtocol = XrayProtocol();
    try {
      final normalized = (configJson.startsWith('vless://') ||
              configJson.startsWith('vmess://'))
          ? configJson.split(RegExp(r'[\r\n]')).first
          : configJson;
      String protocolHint;
      switch (protocol) {
        case VpnProtocol.xrayVless:
        case VpnProtocol.xrayVlessWsTls:
        case VpnProtocol.xrayVlessGrpcTls:
        case VpnProtocol.xrayReality:
          protocolHint = 'vless';
          break;
        case VpnProtocol.xrayVmess:
          protocolHint = 'vmess';
          break;
        case VpnProtocol.graniwg:
          throw UnsupportedError(
              'graniwg не поддерживается в XrayConnectionHandler');
      }
      if (normalized.trim().startsWith('{')) {
        final m = Map<String, dynamic>.from(
          jsonDecode(normalized) as Map<String, dynamic>,
        );
        if (!m.containsKey('protocol')) m['protocol'] = protocolHint;
        xrayProtocol.initializeFromJson(m);
      } else if (normalized.startsWith('vless://') ||
          normalized.startsWith('vmess://')) {
        xrayProtocol.initialize(normalized);
      } else {
        throw Exception('Неверный формат конфигурации Xray');
      }

      final cfg = xrayProtocol.config;
      if (cfg == null) throw Exception('XrayConfig не инициализирован');
      if (protocol == VpnProtocol.xrayReality || cfg.security == 'reality') {
        if (cfg.realityPublicKey == null || cfg.realityPublicKey!.isEmpty) {
          throw Exception('REALITY требует public key (pbk)');
        }
        if (cfg.realityShortId == null || cfg.realityShortId!.isEmpty) {
          throw Exception('REALITY требует shortId (sid)');
        }
        if (cfg.sni == null || cfg.sni!.isEmpty) {
          throw Exception('REALITY требует server name (sni)');
        }
      }

      final nativeJson = cfg.toXrayNativeJsonConfig();
      final effectiveMtu = (mtu ?? 1420).clamp(1280, 1500);
      final success = await NativeVpnService.connect(
        nativeJson,
        protocol: protocol.apiValue,
        mtu: effectiveMtu,
        connectionSessionId: connectionSessionId,
        source: nativeSource,
        runtimeContract: runtimeContract,
        correlationId: correlationId,
      ).timeout(
        AppConfig.connectionTimeout,
        onTimeout: () async {
          _log('Таймаут NativeVpnService.connect');
          return false;
        },
      );
      if (success) {
        xrayProtocol.setConnected(true);
        onConnectStateChanged(true);
        return XrayApplyResult(success: true, xrayProtocol: xrayProtocol);
      }
      return const XrayApplyResult(success: false);
    } on PlatformException catch (e) {
      if (e.code == 'PERMISSION_DENIED') {
        throw VpnPermissionException(
          e.details is Map && e.details['userMessage'] != null
              ? e.details['userMessage'] as String
              : 'VPN разрешение отклонено.',
        );
      }
      rethrow;
    } on VpnPermissionException {
      rethrow;
    } on ConfigMismatchException {
      rethrow;
    } on VpnException {
      return const XrayApplyResult(success: false);
    }
  }
}

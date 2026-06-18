import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../../config/app_config.dart';
import '../api/ipv4_http_client.dart';
import '../errors/error_handler.dart';
import '../http/grani_network_interceptors.dart';
import '../http/grani_request_id.dart';
import '../logger/logger.dart';
import 'network_budget_controller.dart';
import 'network_policy_engine.dart';
import 'vpn_orchestration_spec.dart';

/// Запрос отклонён Policy Engine или Budget (не выполнять HTTP).
class ControlPlaneDeniedException implements Exception {
  ControlPlaneDeniedException(this.reason);
  final String reason;

  @override
  String toString() => 'ControlPlaneDeniedException: $reason';
}

/// Ограничение параллельных исходящих запросов к API (backpressure, ТЗ: 6).
class _ApiConcurrencyGate {
  _ApiConcurrencyGate._();

  static const int maxInFlight = 6;
  static int _inFlight = 0;
  static final List<Completer<void>> _queue = [];

  static Future<void> acquire() async {
    while (_inFlight >= maxInFlight) {
      final c = Completer<void>();
      _queue.add(c);
      await c.future;
    }
    _inFlight++;
  }

  static void release() {
    _inFlight--;
    if (_queue.isNotEmpty) {
      _queue.removeAt(0).complete();
    }
  }
}

String _normalizedBackendPath(Uri uri) {
  var p = uri.path;
  if (p.startsWith('/api/')) {
    p = p.substring(4);
  } else if (p == '/api' || p.startsWith('/api')) {
    p = '/';
  }
  if (p.isEmpty) p = '/';
  return p;
}

/// Пока идёт VPN connect — откладываем фоновые запросы (bootstrap, /auth/me, список устройств).
bool _shouldBlockBackgroundPathDuringVpnConnect(String normalizedPath) {
  final p = normalizedPath.toLowerCase();
  if (p == '/vpn/bootstrap') return true;
  if (p == '/auth/me') return true;
  if (p == '/vpn/devices') return true;
  if (p == '/vpn/status') return true;
  if (p == '/vpn/servers') return true;
  return false;
}

/// Единственная точка создания [Dio] для control-plane: policy → budget → HTTP.
class ControlPlaneClient {
  ControlPlaneClient._();
  static final ControlPlaneClient instance = ControlPlaneClient._();

  late final Dio _dio;
  bool _httpStackInitialized = false;

  /// Задаётся из [VpnService]: при активном connect не выполнять отдельные фоновые control-plane запросы.
  bool Function()? _vpnConnectBlocksBackgroundRequests;

  void attachVpnConnectBlockingGate(bool Function() isConnectInProgress) {
    _vpnConnectBlocksBackgroundRequests = isConnectInProgress;
  }

  final Logger _logger = Logger();
  ErrorHandler? _errorHandler;

  String? Function()? _getTokenCallback;
  Future<bool> Function()? _refreshTokenCallback;
  Future<bool>? _refreshInProgress;

  /// ЗАПРЕЩЕНО создавать Dio вне этого класса. Только для тестов/отладки — не использовать в проде.
  @Deprecated('Use ControlPlaneClient.execute / ApiClient')
  Dio get unsafeDioForTestsOnly {
    if (!_httpStackInitialized) {
      throw StateError('ControlPlaneClient: initializeHttpStack not called');
    }
    return _dio;
  }

  void setTokenProvider(String? Function() getToken) {
    _getTokenCallback = getToken;
  }

  void setRefreshTokenProvider(Future<bool> Function() refreshToken) {
    _refreshTokenCallback = refreshToken;
  }

  /// Инициализация единственного Dio и интерцепторов (вызывается из [ApiClient.initialize]).
  void initializeHttpStack(ErrorHandler errorHandler) {
    if (_httpStackInitialized) {
      return;
    }
    _errorHandler = errorHandler;
    _dio = Dio(BaseOptions(
      baseUrl: AppConfig.apiBaseUrl,
      connectTimeout: const Duration(seconds: 5),
      sendTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 12),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
    ));

    (_dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
      return createIpv4PreferredHttpClient(
        badCertificateCallback: (cert, host, port) =>
            AppConfig.apiDirectIpAllowList.contains(host),
        sniHostWhenConnectingByIp: AppConfig.apiServerHost,
        sniHostForIp: AppConfig.hostForApiIp,
      );
    };

    _dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.extra['grani_skip_connect_cp_gate'] == true) {
            return handler.next(options);
          }
          if (_vpnConnectBlocksBackgroundRequests?.call() != true) {
            return handler.next(options);
          }
          final path = _normalizedBackendPath(options.uri);
          if (_shouldBlockBackgroundPathDuringVpnConnect(path)) {
            return handler.reject(
              DioException(
                requestOptions: options,
                error: ControlPlaneDeniedException('connect_gate'),
                type: DioExceptionType.cancel,
              ),
            );
          }
          return handler.next(options);
        },
      ),
    );

    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        if (options.extra['grani_skip_api_gate'] == true) {
          return handler.next(options);
        }
        await _ApiConcurrencyGate.acquire();
        options.extra['grani_api_gate'] = true;
        return handler.next(options);
      },
      onResponse: (response, handler) {
        if (response.requestOptions.extra['grani_api_gate'] == true) {
          _ApiConcurrencyGate.release();
        }
        return handler.next(response);
      },
      onError: (error, handler) {
        if (error.requestOptions.extra['grani_api_gate'] == true) {
          _ApiConcurrencyGate.release();
        }
        return handler.next(error);
      },
    ));

    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        options.extra['grani_request_start'] = DateTime.now();
        return handler.next(options);
      },
      onResponse: (response, handler) {
        final start =
            response.requestOptions.extra['grani_request_start'] as DateTime?;
        if (start != null) {
          final ms = DateTime.now().difference(start).inMilliseconds;
          ApiClientStaticBridge.lastRequestMs = ms;
          _logger.info(
            'ApiClient: ${response.requestOptions.method} ${response.requestOptions.uri} → ${response.statusCode} (${ms}ms)',
          );
        }
        return handler.next(response);
      },
      onError: (error, handler) {
        final start =
            error.requestOptions.extra['grani_request_start'] as DateTime?;
        if (start != null) {
          final ms = DateTime.now().difference(start).inMilliseconds;
          _logger.info(
            'ApiClient: ${error.requestOptions.method} ${error.requestOptions.uri} → ${error.response?.statusCode ?? error.type} (${ms}ms)',
          );
        }
        return handler.next(error);
      },
    ));

    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        final ct = options.extra['grani_connect_timeout'];
        if (ct is Duration) {
          options.connectTimeout = ct;
        }
        // Явное применение (как у connect): гарантируем per-request send/receive на [RequestOptions],
        // даже если merge [Options.compose] + адаптер ведёт себя неожиданно.
        final st = options.extra['grani_send_timeout'];
        if (st is Duration) {
          options.sendTimeout = st;
        }
        final rt = options.extra['grani_receive_timeout'];
        if (rt is Duration) {
          options.receiveTimeout = rt;
        }
        final uri = options.uri;
        // При запросе на IP-литерал в URL обязателен Host = api hostname (SNI/TLS уже в [createIpv4PreferredHttpClient]).
        // Без корректного Host часть прокси/Cloudflare ведёт себя нестабильно.
        final hostForIp = AppConfig.hostForApiIp(uri.host);
        if (hostForIp != null) {
          options.headers['Host'] = hostForIp;
        }

        try {
          if (_getTokenCallback != null) {
            final token = _getTokenCallback!();
            if (token != null && token.isNotEmpty) {
              options.headers['Authorization'] = 'Bearer $token';
            }
          }
        } catch (e) {
          _logger.warning('ApiClient: Ошибка получения токена: $e');
        }

        final h = options.headers;
        if (h['X-Request-ID'] == null && h['x-request-id'] == null) {
          h['X-Request-ID'] = newGraniRequestId();
        }
        final reqId = h['X-Request-ID'] ?? h['x-request-id'];
        options.extra['grani_started_at_ms'] =
            DateTime.now().millisecondsSinceEpoch;
        final baseUrl =
            '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
        if (AppConfig.enableRouteVerboseLogs) {
          _logger.info(
            'ApiClient: request_id=$reqId method=${options.method} '
            'base_url=$baseUrl resolved_host=${uri.host} uri=${options.uri}',
          );
        } else {
          _logger.debug(
            'ApiClient: request_id=$reqId method=${options.method} '
            'base_url=$baseUrl resolved_host=${uri.host} uri=${options.uri}',
          );
        }
        return handler.next(options);
      },
      onResponse: (response, handler) {
        final req = response.requestOptions;
        final reqId =
            req.headers['X-Request-ID'] ?? req.headers['x-request-id'];
        final respRid = response.headers.value('x-request-id');
        final startedAtMs = req.extra['grani_started_at_ms'] as int?;
        final elapsedMs = startedAtMs == null
            ? null
            : (DateTime.now().millisecondsSinceEpoch - startedAtMs);
        _logger.debug(
          'ApiClient: request_id=${reqId ?? "-"} '
          'response_request_id=${respRid ?? "-"} '
          '${response.requestOptions.method} ${response.requestOptions.path} '
          '- ${response.statusCode} elapsed_ms=${elapsedMs ?? "-"}',
        );
        return handler.next(response);
      },
      onError: (error, handler) {
        final req = error.requestOptions;
        final reqId =
            req.headers['X-Request-ID'] ?? req.headers['x-request-id'];
        final startedAtMs = req.extra['grani_started_at_ms'] as int?;
        final elapsedMs = startedAtMs == null
            ? null
            : (DateTime.now().millisecondsSinceEpoch - startedAtMs);
        _logger.error(
          'ApiClient: request_id=${reqId ?? "-"} '
          'Ошибка ${error.requestOptions.method} ${error.requestOptions.path} '
          '- ${error.response?.statusCode} elapsed_ms=${elapsedMs ?? "-"}',
        );
        final eh = _errorHandler;
        if (eh == null) {
          return handler.next(error);
        }
        final handledError = eh.handleDioError(error);
        if (error.response?.statusCode == 401) {
          _handleUnauthorized(error, handler);
          return;
        }
        return handler.reject(handledError);
      },
    ));

    _dio.interceptors.add(GraniHttpTraceInterceptor(_logger));
    // Без глобального HTTP-retry: для /auth/* дубли ломают одноразовые коды (см. AuthService).

    _logger.info(
        'ControlPlaneClient: HTTP stack инициализирован baseUrl: ${AppConfig.apiBaseUrl}');
    _httpStackInitialized = true;
  }

  Future<void> _handleUnauthorized(
      DioException error, ErrorInterceptorHandler handler) async {
    if (_refreshTokenCallback == null) {
      return handler.reject(error);
    }
    try {
      _refreshInProgress ??= _refreshTokenCallback!().whenComplete(() {
        _refreshInProgress = null;
      });
      final refreshed = await _refreshInProgress!;
      if (refreshed && _getTokenCallback != null) {
        final token = _getTokenCallback!();
        if (token != null) {
          error.requestOptions.headers['Authorization'] = 'Bearer $token';
          _logger.info('ApiClient: Токен обновлен, повторяем запрос');
          try {
            final response = await _dio.fetch(error.requestOptions);
            return handler.resolve(response);
          } catch (e) {
            return handler.reject(error);
          }
        }
      }
    } catch (e) {
      _logger.error('ApiClient: Ошибка обновления токена: $e');
    }
    return handler.reject(error);
  }

  /// Обязательный шлюз: policy → budget → [op] (единственный [Dio] в приложении).
  Future<Response<T>> execute<T>(
      ControlPlanePlane plane, Future<Response<T>> Function(Dio dio) op,
      {bool connectivityDiagnosticsFlush = false}) async {
    if (!_httpStackInitialized) {
      throw StateError(
          'ControlPlaneClient: initializeHttpStack must run before execute');
    }
    final decision = NetworkPolicyEngine.instance.evaluate(
      plane,
      connectivityDiagnosticsFlush: connectivityDiagnosticsFlush,
    );
    if (!decision.allowed) {
      throw ControlPlaneDeniedException(decision.denyReason ?? 'policy');
    }
    if (!NetworkBudgetController.instance.tryAcquireAfterPolicy(decision)) {
      throw ControlPlaneDeniedException('budget');
    }
    try {
      return await op(_dio);
    } finally {
      NetworkBudgetController.instance.release();
    }
  }

  /// Проверка политики для logging plane (без захвата бюджета).
  bool maySendLoggingPlane() {
    return NetworkPolicyEngine.instance
        .evaluate(ControlPlanePlane.logging)
        .allowed;
  }
}

/// Мост для [ApiClient.lastRequestMs] без циклического импорта.
class ApiClientStaticBridge {
  ApiClientStaticBridge._();
  static int? lastRequestMs;
}

@Deprecated('Используйте ControlPlaneClient / ApiClient')
Dio createRawDio() => throw StateError(
    'Use ControlPlaneClient — запрещено создавать Dio вне CPC');

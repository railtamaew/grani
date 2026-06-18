import 'dart:io';

import 'package:dio/dio.dart';

import '../../config/app_config.dart';
import '../errors/error_handler.dart';
import '../logger/logger.dart';
import '../http/grani_network_interceptors.dart';
import '../vpn/control_plane_client.dart';
import '../vpn/control_plane_plane_resolver.dart';
import 'endpoint_router.dart';
import 'preferred_route_storage.dart';

/// Минимальный контракт для подмены в тестах (моки/факи).
abstract class ApiClientInterface {
  Future<Response> get(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    RequestKind? requestKind,
    BootstrapWave? bootstrapWave,
  });
  Future<Response> post(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    RequestKind? requestKind,
    BootstrapWave? bootstrapWave,
  });
  Future<Response> delete(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    RequestKind? requestKind,
    BootstrapWave? bootstrapWave,
  });
  @Deprecated('Используйте ControlPlaneClient.execute')
  Dio get dio;
}

/// Единый HTTP клиент: [EndpointRouter] → [ControlPlaneClient] (policy → budget → Dio).
class ApiClient implements ApiClientInterface {
  static final ApiClient _instance = ApiClient._internal();
  factory ApiClient() => _instance;
  ApiClient._internal();

  static int? get lastRequestMs => ApiClientStaticBridge.lastRequestMs;

  final Logger _logger = Logger();
  final ErrorHandler _errorHandler = ErrorHandler();

  void _logRouteVerbose(String message) {
    if (AppConfig.enableRouteVerboseLogs) {
      _logger.info(message);
    }
  }

  void setTokenProvider(String? Function() getToken) {
    ControlPlaneClient.instance.setTokenProvider(getToken);
  }

  void setRefreshTokenProvider(Future<bool> Function() refreshToken) {
    ControlPlaneClient.instance.setRefreshTokenProvider(refreshToken);
  }

  void initialize() {
    ControlPlaneClient.instance.initializeHttpStack(_errorHandler);
  }

  static bool _isNetworkClassDioError(DioException e) {
    return e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout;
  }

  static String? _extractRequestId(Map<String, dynamic> headers) {
    final rid = headers['X-Request-ID'] ?? headers['x-request-id'];
    return rid?.toString();
  }

  static bool _isRetryEligiblePath({
    required String method,
    required String path,
  }) {
    final m = method.toUpperCase();
    final p = path.trim().toLowerCase();
    if (m == 'POST' &&
        (p == '/auth/send-code' ||
            p == '/auth/verify-code' ||
            p == '/auth/refresh-token')) {
      return true;
    }
    if (m == 'GET' && (p == '/vpn/bootstrap' || p.startsWith('/vpn/config'))) {
      return true;
    }
    // Аналог получения рабочего VPN-конфига перед подключением Xray.
    if (m == 'POST' && p == '/vpn/session/prepare') {
      return true;
    }
    if (m == 'GET' && p.startsWith('/vpn/xray/apply-state')) {
      return true;
    }
    return false;
  }

  /// Транспортные сбои до HTTP-ответа (в т.ч. RST/proxy), пригодные для одного повторного запроса.
  static bool _isRetryEligibleError(DioException e) {
    // Не ретраим ответы сервера (4xx/5xx): только "транспортные" ошибки до ответа.
    if (e.response != null) return false;
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.unknown:
        final err = e.error;
        if (err is SocketException ||
            err is HandshakeException ||
            err is TlsException) {
          return true;
        }
        // Dio кладёт HttpException (reset by peer и т.д.) в unknown без SocketException.
        if (err is HttpException) {
          final m = err.message.toLowerCase();
          return m.contains('connection reset') ||
              m.contains('connection aborted') ||
              m.contains('broken pipe') ||
              m.contains('connection closed');
        }
        final blob =
            '${e.message ?? ""} ${e.error ?? ""}'.toLowerCase();
        return blob.contains('connection reset') ||
            blob.contains('connection aborted') ||
            blob.contains('broken pipe');
      default:
        return false;
    }
  }

  static String _retryReason(DioException e) {
    if (e.type == DioExceptionType.unknown && e.error != null) {
      return e.error.runtimeType.toString();
    }
    return e.type.toString();
  }

  static String _fullUrl(String base, String path) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final p = path.startsWith('/') ? path : '/$path';
    return '$b$p';
  }

  static String _uriKey(Uri u) {
    final s = u.toString();
    return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
  }

  static bool _sameCanonicalBase(String attemptBase, String reference) {
    try {
      final a = Uri.parse(attemptBase);
      final r = Uri.parse(reference);
      return a.host == r.host && a.port == r.port && a.path == r.path;
    } catch (_) {
      return false;
    }
  }

  Future<void> _afterFailedAttempt({
    required String baseStr,
    required String path,
    required RequestKind kind,
    required int attemptIndex,
    required int maxAttempts,
    required DioException e,
  }) async {
    if (attemptIndex < maxAttempts - 1) {
      await PreferredRouteStorage.reportRouteFailure(baseStr, path: path);
    }
    if (_isNetworkClassDioError(e) &&
        _sameCanonicalBase(baseStr, AppConfig.apiBaseUrl)) {
      await PreferredRouteStorage.recordNetworkClassFailure(AppConfig.apiBaseUrl);
    }
  }

  static bool _extraSkipTransportRetry(Options? options) {
    final ex = options?.extra;
    if (ex == null) return false;
    return ex[graniSkipHttpRetryExtra] == true;
  }

  Future<Response<dynamic>> _executeWithRouter({
    required String method,
    required String path,
    required RequestKind kind,
    BootstrapWave? bootstrapWave,
    required Future<Response<dynamic>> Function(String fullUrl) run,
    bool skipTransportRetry = false,
  }) async {
    if (kind == RequestKind.bootstrap && bootstrapWave == null) {
      throw ArgumentError(
        'bootstrapWave обязателен для RequestKind.bootstrap (path=$path)',
      );
    }
    final decision = await EndpointRouter.resolve(
      path: path,
      kind: kind,
      wave: bootstrapWave,
    );
    assert(decision.bases.length == decision.maxAttempts);
    assert(decision.maxAttempts <= 2);
    assert(decision.bases.length <= 2);
    if (kind == RequestKind.logging) {
      assert(decision.maxAttempts == 1 && decision.bases.length == 1);
    }

    for (final baseUri in decision.bases) {
      final baseUrl = _uriKey(baseUri);
      // ignore: avoid_print — явная диагностика маршрута (см. endpoint ranking / base URL).
      print('BASE URL: $baseUrl');
    }

    final basesStr = decision.bases.map((u) => u.toString()).join(', ');
    if (AppConfig.enableRouteVerboseLogs) {
      _logger.info(
        '[router] kind=$kind path=$path bases=[$basesStr] maxAttempts=${decision.maxAttempts}',
      );
    }

    Object? lastError;
    for (var i = 0; i < decision.maxAttempts; i++) {
      assert(i < decision.bases.length);
      final baseStr = _uriKey(decision.bases[i]);
      final fullUrl = _fullUrl(baseStr, path);
      _logRouteVerbose(
        'ApiClient: attempt ${i + 1}/${decision.maxAttempts} base=$baseStr path=$path kind=$kind',
      );
      try {
        final response = await run(fullUrl);
        await PreferredRouteStorage.saveSuccessfulRoute(baseStr);
        return response;
      } on DioException catch (e) {
        final retryOnce = !skipTransportRetry &&
            _isRetryEligiblePath(method: method, path: path) &&
            _isRetryEligibleError(e);
        if (retryOnce) {
          final reqId = _extractRequestId(e.requestOptions.headers);
          _logger.warning(
            '[RETRY] path=$path reason=${_retryReason(e)} attempt=1 request_id=${reqId ?? "none"}',
          );
          try {
            final retried = await run(fullUrl);
            await PreferredRouteStorage.saveSuccessfulRoute(baseStr);
            return retried;
          } on DioException catch (retryError) {
            lastError = retryError;
            await _afterFailedAttempt(
              baseStr: baseStr,
              path: path,
              kind: kind,
              attemptIndex: i,
              maxAttempts: decision.maxAttempts,
              e: retryError,
            );
            if (i == decision.maxAttempts - 1) rethrow;
            continue;
          }
        }
        lastError = e;
        await _afterFailedAttempt(
          baseStr: baseStr,
          path: path,
          kind: kind,
          attemptIndex: i,
          maxAttempts: decision.maxAttempts,
          e: e,
        );
        if (i == decision.maxAttempts - 1) rethrow;
      }
    }
    throw lastError ??
        DioException(
          requestOptions: RequestOptions(path: path),
          error: 'ApiClient: empty decision loop',
        );
  }

  RequestKind _kindOrInfer(String path, RequestKind? requestKind) {
    return requestKind ?? EndpointRouter.resolveKind(path);
  }

  @override
  Future<Response> get(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    RequestKind? requestKind,
    BootstrapWave? bootstrapWave,
  }) async {
    final kind = _kindOrInfer(path, requestKind);
    final plane = ControlPlanePlaneResolver.planeForApiPath(path);
    return _executeWithRouter(
      method: 'GET',
      path: path,
      kind: kind,
      bootstrapWave: bootstrapWave,
      skipTransportRetry: _extraSkipTransportRetry(options),
      run: (fullUrl) => ControlPlaneClient.instance.execute(
        plane,
        (dio) => dio.get(
          fullUrl,
          queryParameters: queryParameters,
          options: options?.copyWith(),
        ),
      ),
    );
  }

  @override
  Future<Response> post(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    RequestKind? requestKind,
    BootstrapWave? bootstrapWave,
  }) async {
    final kind = _kindOrInfer(path, requestKind);
    final plane = ControlPlanePlaneResolver.planeForApiPath(path);
    return _executeWithRouter(
      method: 'POST',
      path: path,
      kind: kind,
      bootstrapWave: bootstrapWave,
      skipTransportRetry: _extraSkipTransportRetry(options),
      run: (fullUrl) => ControlPlaneClient.instance.execute(
        plane,
        (dio) => dio.post(
          fullUrl,
          data: data,
          queryParameters: queryParameters,
          options: options,
          cancelToken: cancelToken,
        ),
      ),
    );
  }

  Future<Response> put(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    RequestKind? requestKind,
    BootstrapWave? bootstrapWave,
  }) async {
    final kind = _kindOrInfer(path, requestKind);
    final plane = ControlPlanePlaneResolver.planeForApiPath(path);
    return _executeWithRouter(
      method: 'PUT',
      path: path,
      kind: kind,
      bootstrapWave: bootstrapWave,
      skipTransportRetry: _extraSkipTransportRetry(options),
      run: (fullUrl) => ControlPlaneClient.instance.execute(
        plane,
        (dio) => dio.put(
          fullUrl,
          data: data,
          queryParameters: queryParameters,
          options: options,
        ),
      ),
    );
  }

  @override
  Future<Response> delete(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    RequestKind? requestKind,
    BootstrapWave? bootstrapWave,
  }) async {
    final kind = _kindOrInfer(path, requestKind);
    final plane = ControlPlanePlaneResolver.planeForApiPath(path);
    return _executeWithRouter(
      method: 'DELETE',
      path: path,
      kind: kind,
      bootstrapWave: bootstrapWave,
      skipTransportRetry: _extraSkipTransportRetry(options),
      run: (fullUrl) => ControlPlaneClient.instance.execute(
        plane,
        (dio) => dio.delete(
          fullUrl,
          data: data,
          queryParameters: queryParameters,
          options: options,
        ),
      ),
    );
  }

  Future<Response> patch(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    RequestKind? requestKind,
    BootstrapWave? bootstrapWave,
  }) async {
    final kind = _kindOrInfer(path, requestKind);
    final plane = ControlPlanePlaneResolver.planeForApiPath(path);
    return _executeWithRouter(
      method: 'PATCH',
      path: path,
      kind: kind,
      bootstrapWave: bootstrapWave,
      skipTransportRetry: _extraSkipTransportRetry(options),
      run: (fullUrl) => ControlPlaneClient.instance.execute(
        plane,
        (dio) => dio.patch(
          fullUrl,
          data: data,
          queryParameters: queryParameters,
          options: options,
        ),
      ),
    );
  }

  @override
  @Deprecated('Используйте ControlPlaneClient.execute')
  Dio get dio => ControlPlaneClient.instance.unsafeDioForTestsOnly;
}

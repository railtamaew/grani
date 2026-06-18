import 'package:dio/dio.dart';

import '../logger/logger.dart';

/// Поместите в [RequestOptions.extra] со значением `true`, чтобы явно отключить
/// повтор на уровне стека, если он снова будет добавлен.
const String graniSkipHttpRetryExtra = 'grani_skip_retry';

String? _requestIdFrom(RequestOptions o) {
  final h = o.headers;
  final v = h['X-Request-ID'] ?? h['x-request-id'];
  if (v == null) return null;
  return v.toString();
}

String _describeBody(dynamic data) {
  if (data == null) return 'null';
  if (data is String) return 'String len=${data.length}';
  if (data is List) return 'List len=${data.length}';
  if (data is Map) return 'Map keys=${data.length}';
  return data.runtimeType.toString();
}

/// Трассировка: старт запроса, приход заголовков и тела ответа.
class GraniHttpTraceInterceptor extends Interceptor {
  GraniHttpTraceInterceptor(this._logger);

  final Logger _logger;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final id = _requestIdFrom(options) ?? '-';
    _logger.info(
      'GraniHttp: request start method=${options.method} url=${options.uri} request_id=$id',
      'GraniHttp',
    );
    handler.next(options);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    final id = _requestIdFrom(response.requestOptions) ?? '-';
    final names = response.headers.map.keys.join(',');
    _logger.info(
      'GraniHttp: response headers received status=${response.statusCode} '
      'header_names=[$names] request_id=$id',
      'GraniHttp',
    );
    _logger.info(
      'GraniHttp: response body received ${_describeBody(response.data)} request_id=$id',
      'GraniHttp',
    );
    handler.next(response);
  }
}

import 'package:dio/dio.dart';
import 'package:mobile_app/core/api/api_client.dart';
import 'package:mobile_app/core/api/endpoint_router.dart';

/// Фейк для тестов: реализует ApiClientInterface, по умолчанию post/get бросают DioException.
class FakeApiClient implements ApiClientInterface {
  Response? stubPostResponse;
  Response? stubGetResponse;
  DioException? postException;
  DioException? getException;

  @override
  Dio get dio => throw UnimplementedError('FakeApiClient.dio не используется в текущих тестах');

  @override
  Future<Response> get(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    RequestKind? requestKind,
    BootstrapWave? bootstrapWave,
  }) async {
    if (stubGetResponse != null) return stubGetResponse!;
    throw getException ?? DioException(
      requestOptions: RequestOptions(path: path),
      type: DioExceptionType.connectionTimeout,
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
    if (stubPostResponse != null) return stubPostResponse!;
    throw postException ?? DioException(
      requestOptions: RequestOptions(path: path, data: data),
      type: DioExceptionType.connectionTimeout,
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
    throw DioException(
      requestOptions: RequestOptions(path: path),
      type: DioExceptionType.connectionTimeout,
    );
  }
}

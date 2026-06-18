import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/core/api/api_client.dart';
import '../support/fake_api_client.dart';
import 'package:mobile_app/core/cache/cache_service.dart';
import 'package:mobile_app/core/errors/error_handler.dart';
import 'package:mobile_app/core/logger/logger.dart';
import 'package:mobile_app/core/storage/storage_service.dart';
import 'package:mobile_app/models/vpn_protocol.dart';
import 'package:mobile_app/services/connection_logger.dart';
import 'package:mobile_app/services/vpn_service.dart';
import '../support/auth_mock_for_vpn.dart';

/// Юнит-тесты VpnService с подменой зависимостей (факи/моки).
/// Проверяют: инъекция ApiClientInterface, установка lastConnectionErrorMessage при ошибке connect.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('VpnService с FakeApiClient', () {
    test('при инъекции FakeApiClient connect() при ошибке выставляет lastConnectionErrorMessage', () async {
      ApiClient().initialize();
      final fakeApi = FakeApiClient();
      final auth = MockAuthForVpn();
      stubVpnAuthDefaults(auth);
      final service = VpnService(
        apiClient: fakeApi,
        logger: Logger(),
        cacheService: CacheService(),
        storageService: StorageService(),
        errorHandler: ErrorHandler(),
        connectionLogger: ConnectionLogger(),
        authService: auth,
        skipInitialize: true,
      );
      addTearDown(service.dispose);

      var connectFailed = false;
      try {
        final result = await service.connect();
        connectFailed = !result;
      } catch (_) {
        connectFailed = true;
      }

      if (connectFailed) {
        expect(
          service.lastConnectionErrorMessage != null && service.lastConnectionErrorMessage!.isNotEmpty,
          isTrue,
          reason: 'После неудачного connect() lastConnectionErrorMessage должен быть непустым',
        );
      }
    });

    test('FakeApiClient.post по умолчанию бросает DioException', () async {
      final fakeApi = FakeApiClient();
      expect(
        () => fakeApi.post('/vpn/connect', data: {}),
        throwsA(isA<DioException>()),
      );
    });

    test('FakeApiClient с stub post возвращает заданный Response', () async {
      final fakeApi = FakeApiClient();
      fakeApi.stubPostResponse = Response(
        requestOptions: RequestOptions(path: '/vpn/connect'),
        statusCode: 200,
        data: {'ok': true},
      );
      final response = await fakeApi.post('/vpn/connect', data: {});
      expect(response.statusCode, 200);
      expect(response.data, {'ok': true});
    });
  });

  group('VpnService getHandlerFor (фаза 3.2)', () {
    late VpnService service;

    setUp(() {
      final auth = MockAuthForVpn();
      stubVpnAuthDefaults(auth);
      service = VpnService(
        apiClient: FakeApiClient(),
        logger: Logger(),
        cacheService: CacheService(),
        storageService: StorageService(),
        errorHandler: ErrorHandler(),
        connectionLogger: ConnectionLogger(),
        authService: auth,
        skipInitialize: true,
      );
    });

    tearDown(() => service.dispose());

    test('возвращает handler для всех поддерживаемых протоколов', () {
      expect(service.getHandlerFor(VpnProtocol.xrayVless), isNotNull);
      expect(service.getHandlerFor(VpnProtocol.xrayVmess), isNotNull);
      expect(service.getHandlerFor(VpnProtocol.xrayReality), isNotNull);
    });
  });
}

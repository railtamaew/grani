import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/core/api/api_client.dart';
import '../support/fake_api_client.dart';
import 'package:mobile_app/core/cache/cache_service.dart';
import 'package:mobile_app/core/errors/error_handler.dart';
import 'package:mobile_app/core/logger/logger.dart';
import 'package:mobile_app/core/storage/storage_service.dart';
import 'package:mobile_app/core/vpn_state_machine.dart';
import 'package:mobile_app/models/vpn_protocol.dart';
import 'package:mobile_app/services/connection_logger.dart';
import 'package:mobile_app/services/vpn_service.dart';
import '../support/auth_mock_for_vpn.dart';

/// Юнит-тесты VpnService с подменой зависимостей (факи/моки).
/// Проверяют: инъекция ApiClientInterface, установка lastConnectionErrorMessage при ошибке connect.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('VpnService с FakeApiClient', () {
    test(
        'при инъекции FakeApiClient connect() при ошибке выставляет lastConnectionErrorMessage',
        () async {
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
          service.lastConnectionErrorMessage != null &&
              service.lastConnectionErrorMessage!.isNotEmpty,
          isTrue,
          reason:
              'После неудачного connect() lastConnectionErrorMessage должен быть непустым',
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

    test('параллельные control-plane refresh используют один in-flight запрос',
        () async {
      const connectivityChannel =
          MethodChannel('dev.fluttercommunity.plus/connectivity');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        connectivityChannel,
        (_) async => <String>['wifi'],
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(connectivityChannel, null),
      );
      final fakeApi = FakeApiClient();
      final response = Completer<Response>();
      var getCalls = 0;
      fakeApi.onGet = (path) {
        expect(path, '/vpn/control-plane-snapshot');
        getCalls += 1;
        return response.future;
      };
      final auth = MockAuthForVpn();
      stubVpnAuthDefaults(auth, token: 'test-token');
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

      final first = service.refreshControlPlaneSnapshot(auth, force: true);
      final second = service.refreshControlPlaneSnapshot(auth, force: true);
      await Future<void>.delayed(Duration.zero);
      expect(getCalls, 1);

      response.complete(
        Response(
          requestOptions: RequestOptions(path: '/vpn/control-plane-snapshot'),
          statusCode: 200,
          data: const <String, dynamic>{'servers': <dynamic>[]},
        ),
      );
      await Future.wait<void>(<Future<void>>[first, second]);

      expect(getCalls, 1);
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
      for (final protocol in VpnProtocol.values) {
        expect(
          service.getHandlerFor(protocol),
          isNotNull,
          reason:
              'После разнесения protocol adapters каждый VpnProtocol должен иметь handler: $protocol',
        );
      }
    });

    test('initial lifecycle state remains idle/off after refactor', () {
      expect(service.vpnConnectionState, VpnConnectionState.idle);
      expect(service.vpnUiSessionState, VpnUiSessionState.off);
      expect(service.isConnected, isFalse);
      expect(service.isConnecting, isFalse);
      expect(service.isDisconnecting, isFalse);
      expect(service.lastConnectionErrorMessage, isNull);
      expect(service.connectedWithAckDelayForTest, isFalse);
      expect(service.lastConnectFailReasonForTest, isNull);
    });

    test('disconnect is idempotent when VPN is already off', () async {
      final result = await service.disconnect(source: 'unit_test');

      expect(result, isFalse);
      expect(service.vpnConnectionState, VpnConnectionState.idle);
      expect(service.vpnUiSessionState, VpnUiSessionState.off);
      expect(service.isConnected, isFalse);
      expect(service.isConnecting, isFalse);
      expect(service.isDisconnecting, isFalse);
    });

    test('GraniWG handler validates only WireGuard-like configs', () {
      final handler = service.getHandlerFor(VpnProtocol.graniwg);
      expect(handler, isNotNull);

      expect(handler!.isConfigValid('', VpnProtocol.graniwg), isFalse);
      expect(
        handler.isConfigValid(
            '[Interface]\nPrivateKey = test\n', VpnProtocol.graniwg),
        isFalse,
      );
      expect(
        handler.isConfigValid(
          '[Interface]\nPrivateKey = test\n\n[Peer]\nPublicKey = peer\n',
          VpnProtocol.graniwg,
        ),
        isTrue,
      );
    });

    test('Xray handlers reject obviously invalid configs', () {
      for (final protocol in VpnProtocol.values.where((p) => p.isXray)) {
        final handler = service.getHandlerFor(protocol);
        expect(handler, isNotNull);
        expect(
          handler!.isConfigValid('', protocol),
          isFalse,
          reason: 'Empty Xray config must not be accepted for $protocol',
        );
        expect(
          handler.isConfigValid('not-json', protocol),
          isFalse,
          reason: 'Non-JSON Xray config must not be accepted for $protocol',
        );
      }
    });
  });
}

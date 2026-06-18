/// Тесты XrayConnectionHandler: reconnect из кэша (без create-client), 400 → force disconnect → retry.
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/core/api/api_client.dart';
import 'package:mobile_app/core/api/endpoint_router.dart';
import 'package:mobile_app/models/server.dart';
import 'package:mobile_app/models/vpn_protocol.dart';
import 'package:mobile_app/services/native_vpn_service.dart';
import 'package:mobile_app/services/xray_connection_handler.dart';

const _connectivityChannel = MethodChannel('dev.fluttercommunity.plus/connectivity');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Server testServer;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_connectivityChannel, (call) async {
      if (call.method == 'check') return ['wifi'];
      return null;
    });
    testServer = Server(
      id: '1',
      name: 'Test',
      country: 'RU',
      city: 'Moscow',
      ip: '1.2.3.4',
      port: 443,
      isActive: true,
      currentLoad: 0,
      maxLoad: 100,
      ping: 0,
      supportedProtocols: ['xray_vless', 'xray_vmess'],
    );
  });

  group('XrayConnectionHandler - reconnect из кэша', () {
    test('getCachedConfig возвращает конфиг из кэша без вызова API', () async {
      const cachedConfig = '{"add":"1.2.3.4","port":4443,"id":"test-uuid"}';
      final postCalls = <MapEntry<String, dynamic>>[];

      final mockApi = _MockApiClient(
        onPost: (path, data) {
          postCalls.add(MapEntry(path, data));
          return Future.value(Response(
            requestOptions: RequestOptions(path: path),
            statusCode: 200,
            data: {},
          ));
        },
      );
      final mockCache = _MockXrayConfigCache(
        getValue: (serverId, protocol) async => (
              config: cachedConfig,
              clientId: 'test-client-id',
              serverConfigRevision: null,
              configEtag: null,
              contentSha256: null,
            ),
      );
      final handler = XrayConnectionHandler(
        apiClient: mockApi,
        cache: mockCache,
        forceDisconnectOnServer: (_) async => true,
      );

      final result = await handler.getCachedConfig(testServer, VpnProtocol.xrayVless);

      expect(result, isNotNull);
      expect(result!.jsonConfig, equals(cachedConfig));
      expect(result.clientId, equals('test-client-id'));
      expect(postCalls, isEmpty, reason: 'При использовании кэша create-client не вызывается');
    });

    test('getCachedConfig возвращает null если кэш пуст', () async {
      final mockApi = _MockApiClient(
        onPost: (path, data) => Future.value(Response(
          requestOptions: RequestOptions(path: path),
          statusCode: 200,
          data: {},
        )),
      );
      final mockCache = _MockXrayConfigCache(getValue: (_, __) async => null);
      final handler = XrayConnectionHandler(
        apiClient: mockApi,
        cache: mockCache,
        forceDisconnectOnServer: (_) async => true,
      );

      final result = await handler.getCachedConfig(testServer, VpnProtocol.xrayVless);

      expect(result, isNull);
    });
  });

  group('XrayConnectionHandler - 400 «уже подключено» → force disconnect → retry', () {
    test('при 400 «уже подключено» вызываются disconnect с device_id и повтор create-client', () async {
      final callOrder = <String>[];
      var createClientCallCount = 0;

      final mockApi = _MockApiClient(
        onPost: (path, data) {
          if (path.contains('/v2/vpn/xray/connect') ||
              path.contains('create-client') ||
              path == '/vpn/xray/create-client') {
            callOrder.add('create-client');
            createClientCallCount++;
            if (createClientCallCount == 1) {
              throw DioException(
                requestOptions: RequestOptions(path: path),
                response: Response(
                  requestOptions: RequestOptions(path: path),
                  statusCode: 400,
                  data: {'detail': 'Устройство уже подключено'},
                ),
                type: DioExceptionType.badResponse,
              );
            }
            return Future.value(Response(
              requestOptions: RequestOptions(path: path),
              statusCode: 200,
              data: {
                'success': true,
                'client_id': 'new-client-id',
                'json_config': {'add': '1.2.3.4', 'port': 4443, 'id': 'new-uuid'},
                'ip_address': '10.0.0.2',
              },
            ));
          }
          return Future.value(Response(requestOptions: RequestOptions(path: path), statusCode: 200, data: {}));
        },
      );
      final mockCache = _MockXrayConfigCache(getValue: (_, __) async => null);
      final handler = XrayConnectionHandler(
        apiClient: mockApi,
        cache: mockCache,
        forceDisconnectOnServer: (_) async {
          callOrder.add('disconnect');
          return true;
        },
      );

      final result = await handler.fetchConfig(
        token: 'token',
        server: testServer,
        protocol: VpnProtocol.xrayVless,
        deviceId: 'device-123',
      );

      expect(result.clientId, equals('new-client-id'));
      expect(result.jsonConfig, contains('new-uuid'));
      expect(
        callOrder,
        equals([
          'create-client',
          'disconnect',
          'create-client',
        ]),
      );
    });
  });

  group('XrayConnectionHandler.applyConfig - native commit contract', () {
    const MethodChannel vpnChannel = MethodChannel('com.granivpn.mobile/vpn');

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(vpnChannel, (MethodCall methodCall) async {
        if (methodCall.method == 'connect') return false;
        if (methodCall.method == 'disconnect') return true;
        if (methodCall.method == 'isXrayAvailable') return true;
        if (methodCall.method == 'requestPermission') return true;
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(vpnChannel, null);
    });

    test('возвращает success=false если NativeVpnService.connect не дал commit', () async {
      final mockApi = _MockApiClient(
        onPost: (path, data) => Future.value(
          Response(
            requestOptions: RequestOptions(path: path),
            statusCode: 200,
            data: {},
          ),
        ),
      );
      final handler = XrayConnectionHandler(
        apiClient: mockApi,
        cache: _MockXrayConfigCache(getValue: (_, __) async => null),
        forceDisconnectOnServer: (_) async => true,
      );
      var connectedCallbackInvoked = false;
      final result = await handler.applyConfig(
        configJson: '{"add":"1.2.3.4","port":4443,"id":"uuid-1","protocol":"vless","net":"tcp","tls":"none"}',
        protocol: VpnProtocol.xrayVless,
        onConnectStateChanged: (connected) {
          connectedCallbackInvoked = connected;
        },
      );

      expect(result.success, isFalse);
      expect(result.xrayProtocol, isNull);
      expect(connectedCallbackInvoked, isFalse);
    });

    test('пробрасывает VpnPermissionException при отказе разрешения', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(vpnChannel, (MethodCall methodCall) async {
        if (methodCall.method == 'connect') {
          throw PlatformException(
            code: 'PERMISSION_DENIED',
            message: 'denied',
            details: {'userMessage': 'VPN permission denied by user'},
          );
        }
        return null;
      });

      final mockApi = _MockApiClient(
        onPost: (path, data) => Future.value(
          Response(
            requestOptions: RequestOptions(path: path),
            statusCode: 200,
            data: {},
          ),
        ),
      );
      final handler = XrayConnectionHandler(
        apiClient: mockApi,
        cache: _MockXrayConfigCache(getValue: (_, __) async => null),
        forceDisconnectOnServer: (_) async => true,
      );

      expect(
        () => handler.applyConfig(
          configJson:
              '{"add":"1.2.3.4","port":4443,"id":"uuid-2","protocol":"vless","net":"tcp","tls":"none"}',
          protocol: VpnProtocol.xrayVless,
          onConnectStateChanged: (_) {},
        ),
        throwsA(isA<VpnPermissionException>()),
      );
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_connectivityChannel, null);
  });
}

class _MockApiClient implements ApiClientInterface {
  _MockApiClient({required this.onPost});

  final Future<Response> Function(String path, dynamic data) onPost;

  @override
  Future<Response> get(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    RequestKind? requestKind,
    BootstrapWave? bootstrapWave,
  }) =>
      throw UnimplementedError();

  @override
  Future<Response> post(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    RequestKind? requestKind,
    BootstrapWave? bootstrapWave,
  }) =>
      onPost(path, data);

  @override
  Future<Response> delete(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    RequestKind? requestKind,
    BootstrapWave? bootstrapWave,
  }) =>
      throw UnimplementedError();

  @override
  Dio get dio => throw UnimplementedError();
}

class _MockXrayConfigCache implements XrayConfigCache {
  _MockXrayConfigCache({required this.getValue});

  final Future<
      ({
        String config,
        String? clientId,
        String? serverConfigRevision,
        String? configEtag,
        String? contentSha256,
      })?> Function(String serverId, String protocol) getValue;

  @override
  Future<
      ({
        String config,
        String? clientId,
        String? serverConfigRevision,
        String? configEtag,
        String? contentSha256,
      })?> get(String serverId, String protocol) => getValue(serverId, protocol);

  @override
  Future<void> set(
    String serverId,
    String protocol,
    String config, {
    String? clientId,
    String? serverConfigRevision,
    String? configEtag,
  }) async {}
}

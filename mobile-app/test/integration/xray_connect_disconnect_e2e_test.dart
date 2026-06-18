/// E2E-интеграционный тест: выбор сервера → конфиг → подключение → отключение.
///
/// Проверяет полный цикл подключения Xray с моками платформы и API.
/// NativeVpnService и API замоканы; реальное туннелирование не выполняется.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/core/api/api_client.dart';
import 'package:mobile_app/core/api/endpoint_router.dart';
import 'package:mobile_app/core/cache/cache_service.dart';
import 'package:mobile_app/core/errors/error_handler.dart';
import 'package:mobile_app/core/logger/logger.dart';
import 'package:mobile_app/core/storage/storage_service.dart';
import 'package:mobile_app/models/server.dart';
import 'package:mobile_app/services/auth_service.dart';
import 'package:mobile_app/services/connection_logger.dart';
import 'package:mobile_app/services/vpn_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _connectivityChannel =
    MethodChannel('dev.fluttercommunity.plus/connectivity');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel vpnChannel = MethodChannel('com.granivpn.mobile/vpn');

  late StorageService storageService;
  late CacheService cacheService;
  late E2EFakeApiClient fakeApi;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    storageService = StorageService();
    await storageService.initialize();
    cacheService = CacheService();
    await cacheService.initialize();
  });

  setUp(() {
    fakeApi = E2EFakeApiClient();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_connectivityChannel, (call) async {
      if (call.method == 'check') return <String>['wifi'];
      return null;
    });
    // Mock MethodChannel для NativeVpnService
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(vpnChannel, (MethodCall methodCall) async {
      switch (methodCall.method) {
        case 'connect':
          return true;
        case 'disconnect':
          return true;
        case 'isXrayAvailable':
          return true;
        case 'requestPermission':
          return true;
        case 'getStatus':
          return {'connected': false};
        case 'getTrafficStats':
          return {'rx_bytes': 100, 'tx_bytes': 50};
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_connectivityChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(vpnChannel, null);
  });

  group('E2E: выбор сервера → конфиг → подключение → отключение', () {
    test('выбор сервера → конфиг → подключение → отключение', () async {
      // Эмулируем Android для Xray
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
      });

      final fakeAuth = FakeAuthService('test_token_e2e');

      // Предзаполняем кэш серверов (refreshServers при отсутствии токена грузит из кэша)
      final serverJson = {
        'id': 1,
        'name': 'Test Server',
        'country': 'RU',
        'city': 'Moscow',
        'ip_address': '1.2.3.4',
        'wireguard_port': 443,
        'is_active': true,
        'current_users': 10,
        'max_users': 100,
        'ping_ms': 50.0,
        'supported_protocols': ['xray_reality', 'xray_vless', 'xray_vmess'],
      };
      await cacheService.setString(
        'cached_servers',
        jsonEncode([serverJson]),
        ttl: const Duration(hours: 24),
      );

      final service = VpnService(
        apiClient: fakeApi,
        logger: Logger(),
        cacheService: cacheService,
        storageService: storageService,
        errorHandler: ErrorHandler(),
        connectionLogger: ConnectionLogger(),
        authService: fakeAuth,
        skipInitialize: true,
      );
      addTearDown(service.dispose);

      // 1. Загружаем серверы из кэша (или через API при наличии токена)
      await service.refreshServers(force: true);
      // refreshServers с токеном вызовет API; с FakeAuth токен есть — но API вызов идёт к fakeApi.
      // FakeAuth даёт токен, значит refreshServers пойдёт в API. FakeApi.get(servers) вернёт список.
      expect(service.servers, isNotEmpty,
          reason: 'Должны быть загружены серверы');
      expect(service.selectedServer, isNotNull,
          reason: 'Должен быть выбран сервер по умолчанию');

      // 2. Подключаемся (create-client мок вернёт json_config, NativeVpnService.connect мок вернёт true)
      final connected = await service.connect();
      expect(connected, isTrue, reason: 'Подключение должно завершиться успешно');
      expect(service.isConnected, isTrue,
          reason: 'Сервис должен быть в состоянии подключено');
      expect(fakeApi.lastConnectPath, isNotNull,
          reason: 'Должен быть выполнен connect-запрос за конфигом');
      expect(
        fakeApi.lastConnectPath!.contains('/v2/vpn/xray/connect') ||
            fakeApi.lastConnectPath!.contains('/vpn/xray/create-client') ||
            fakeApi.lastConnectPath!.contains('session/prepare'),
        isTrue,
        reason: 'Используется v2/legacy connect endpoint для получения Xray config',
      );

      // 3. Отключаемся (в тестах без прокачки кадров используем debugBypassFrameDelay).
      // reason != user: иначе срабатывает post_connect debounce (8s) и disconnect не выполняется.
      VpnService.debugBypassFrameDelay = true;
      addTearDown(() {
        VpnService.debugBypassFrameDelay = false;
      });
      await service.disconnect(
        reason: VpnDisconnectReason.protocolSwitch,
        source: 'e2e_test',
      );
      expect(service.isConnected, isFalse,
          reason: 'После disconnect сервис должен быть отключён');

      // disconnect всегда шлёт device_id в теле (как в приложении)
      expect(fakeApi.lastDisconnectPostData, isNotNull,
          reason: 'Должен быть вызван POST /vpn/disconnect');
      expect(fakeApi.lastDisconnectPostData!['device_id'], isNotNull,
          reason: 'Тело disconnect должно содержать device_id');
      expect((fakeApi.lastDisconnectPostData!['device_id'] as String).isNotEmpty, isTrue);
    });
  });
}

/// Фейк AuthService для тестов: возвращает заданный токен.
class FakeAuthService extends AuthService {
  FakeAuthService(this._token);

  final String _token;

  @override
  String? get token => _token;

  @override
  Future<bool> ensureValidToken() async => true;

  @override
  Future<void> waitForTokenLoad() async {}
}

/// Фейк API: возвращает серверы, create-client с json_config, device/register.
/// Записывает последний вызов POST /vpn/disconnect для проверки тела (device_id).
class E2EFakeApiClient implements ApiClientInterface {
  /// Последний data, переданный в post('/vpn/disconnect', data: ...).
  Map<String, dynamic>? lastDisconnectPostData;
  String? lastConnectPath;

  static const _validXrayJsonConfig = '''
{
  "add": "example.com",
  "port": 443,
  "id": "12345678-1234-1234-1234-123456789012",
  "protocol": "vless",
  "tls": "reality",
  "pbk": "dGVzdF9wdWJsaWNfa2V5X2Zvcl9yZWFsaXR5",
  "sni": "www.google.com",
  "sid": "abcd1234",
  "network": "tcp"
}
''';

  @override
  Dio get dio => throw UnimplementedError('E2EFakeApiClient.dio не используется');

  @override
  Future<Response> get(String path,
      {Map<String, dynamic>? queryParameters,
      Options? options,
      RequestKind? requestKind,
      BootstrapWave? bootstrapWave}) async {
    if (path.contains('servers') || path == '/vpn/servers') {
      final servers = [
        {
          'id': 1,
          'name': 'Test Server',
          'country': 'RU',
          'city': 'Moscow',
          'ip_address': '1.2.3.4',
          'wireguard_port': 443,
          'is_active': true,
          'current_users': 10,
          'max_users': 100,
          'ping_ms': 50.0,
          'supported_protocols': ['xray_reality', 'xray_vless', 'xray_vmess'],
        },
      ];
      return Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: servers,
      );
    }
    throw DioException(
      requestOptions: RequestOptions(path: path),
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 404,
      ),
    );
  }

  @override
  Future<Response> post(String path,
      {dynamic data,
      Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken,
      RequestKind? requestKind,
      BootstrapWave? bootstrapWave}) async {
    if (path.contains('session/prepare') ||
        path.contains('create-client') ||
        path.contains('/v2/vpn/xray/connect') ||
        path == '/vpn/xray/create-client') {
      lastConnectPath = path;
      final jsonConfig = jsonDecode(_validXrayJsonConfig) as Map<String, dynamic>;
      return Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: {
          'success': true,
          'client_id': 'test_client_001',
          'ip_address': '10.0.0.1',
          'json_config': jsonConfig,
        },
      );
    }
    if (path.contains('device/register') || path == '/vpn/device/register') {
      return Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: {'success': true},
      );
    }
    if (path.contains('disconnect') || path == '/vpn/disconnect') {
      lastDisconnectPostData = data is Map<String, dynamic>
          ? Map<String, dynamic>.from(data)
          : (data != null ? <String, dynamic>{} : null);
      return Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
      );
    }
    if (path.contains('logs/send') || path.contains('log')) {
      return Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: {'success': true},
      );
    }
    throw DioException(
      requestOptions: RequestOptions(path: path),
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 404,
      ),
    );
  }

  @override
  Future<Response> delete(String path,
      {dynamic data,
      Map<String, dynamic>? queryParameters,
      Options? options,
      RequestKind? requestKind,
      BootstrapWave? bootstrapWave}) async {
    throw UnimplementedError('E2EFakeApiClient.delete');
  }
}

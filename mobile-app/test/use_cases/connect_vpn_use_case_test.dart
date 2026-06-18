import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mobile_app/core/api/api_client.dart';
import 'package:mobile_app/core/cache/cache_service.dart';
import 'package:mobile_app/core/errors/error_handler.dart';
import 'package:mobile_app/core/logger/logger.dart';
import 'package:mobile_app/core/storage/storage_service.dart';
import 'package:mobile_app/services/auth_service.dart';
import 'package:mobile_app/services/connection_logger.dart';
import 'package:mobile_app/services/vpn_service.dart';
import 'package:mobile_app/use_cases/connect_vpn_use_case.dart';
import '../support/fake_api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _vpnChannel = MethodChannel('com.granivpn.mobile/vpn');
const _connectivityChannel =
    MethodChannel('dev.fluttercommunity.plus/connectivity');

class _MockAuth extends Mock implements AuthService {}

/// Юнит-тесты ConnectVpnUseCase.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VpnService vpnService;
  late _MockAuth mockAuth;
  late FakeApiClient fakeApi;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.initialize();
  });

  setUp(() {
    fakeApi = FakeApiClient();
    mockAuth = _MockAuth();
    when(() => mockAuth.waitForTokenLoad()).thenAnswer((_) async {});
    when(() => mockAuth.hasPendingDeviceLimit).thenReturn(false);
    when(() => mockAuth.ensureNetworkReady()).thenAnswer((_) async {});
    // Дефолты, чтобы mocktail не отдавал null для bool после других тестов в том же процессе.
    when(() => mockAuth.hasActiveSubscription).thenReturn(false);
    when(() => mockAuth.trialSecondsLeft).thenReturn(0);
    when(() => mockAuth.token).thenReturn(null);
    when(() => mockAuth.ensureValidToken()).thenAnswer((_) async => false);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_connectivityChannel, (call) async {
      if (call.method == 'check') {
        return [ConnectivityResult.wifi.name];
      }
      return null;
    });

    vpnService = VpnService(
      apiClient: fakeApi,
      logger: Logger(),
      cacheService: CacheService(),
      storageService: StorageService(),
      errorHandler: ErrorHandler(),
      connectionLogger: ConnectionLogger(),
      authService: mockAuth,
      skipInitialize: true,
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_vpnChannel, (call) async {
      switch (call.method) {
        case 'requestPermission':
          return true;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    vpnService.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_vpnChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_connectivityChannel, null);
  });

  group('ConnectVpnUseCase.connect', () {
    // Важно: этот тест первым в группе — после прогона сотен тестов mocktail иногда «липнет» к старым stub
    // для hasActiveSubscription; изоляция уменьшает флейки в полном suite.
    test('при hasActiveSubscription=true не возвращает ConnectNoSubscription при истёкшем триале', () async {
      when(() => mockAuth.hasActiveSubscription).thenReturn(true);
      when(() => mockAuth.trialSecondsLeft).thenReturn(0);
      when(() => mockAuth.token).thenReturn('t');
      when(() => mockAuth.ensureValidToken()).thenAnswer((_) async => true);

      final useCase = ConnectVpnUseCase(
        vpnService: vpnService,
        authService: mockAuth,
      );
      final result = await useCase.connect();

      expect(result, isNot(isA<ConnectNoSubscription>()));
    });

    test('возвращает ConnectNoSubscription при отсутствии подписки и триала', () async {
      when(() => mockAuth.hasActiveSubscription).thenReturn(false);
      when(() => mockAuth.trialSecondsLeft).thenReturn(0);

      final useCase = ConnectVpnUseCase(
        vpnService: vpnService,
        authService: mockAuth,
      );
      final result = await useCase.connect();

      expect(result, isA<ConnectNoSubscription>());
      expect(
        (result as ConnectNoSubscription).message.toLowerCase(),
        anyOf(contains('подписка'), contains('subscription')),
      );
    });

    test('возвращает ConnectFailure при отказе в разрешении VPN', () async {
      when(() => mockAuth.hasActiveSubscription).thenReturn(false);
      when(() => mockAuth.trialSecondsLeft).thenReturn(600);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_vpnChannel, (call) async {
        if (call.method == 'requestPermission') return false;
        return null;
      });

      final useCase = ConnectVpnUseCase(
        vpnService: vpnService,
        authService: mockAuth,
      );
      final result = await useCase.connect();

      expect(result, isA<ConnectFailure>());
      final failMsg = (result as ConnectFailure).userMessage.toLowerCase();
      // Сначала может сработать пустой список серверов; при успешной загрузке — отказ в разрешении VPN.
      expect(
        failMsg,
        anyOf(
          contains('разрешение'),
          contains('permission'),
          contains('server'),
          contains('сервер'),
        ),
      );
    });
  });
}

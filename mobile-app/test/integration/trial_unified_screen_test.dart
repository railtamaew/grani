import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobile_app/core/cache/cache_service.dart';
import 'package:mobile_app/core/errors/error_handler.dart';
import 'package:mobile_app/core/logger/logger.dart';
import 'package:mobile_app/core/storage/storage_service.dart';
import 'package:mobile_app/l10n/app_localizations.dart';
import 'package:mobile_app/screens/trial_unified_screen.dart';
import 'package:mobile_app/services/auth_service.dart';
import 'package:mobile_app/services/connection_logger.dart';
import 'package:mobile_app/services/vpn_service.dart';
import '../support/fake_api_client.dart';

const _vpnChannel = MethodChannel('com.granivpn.mobile/vpn');
const _connectivityChannel =
    MethodChannel('dev.fluttercommunity.plus/connectivity');

/// Интеграционные тесты TrialUnifiedScreen.
/// Проверяют отрисовку экрана и базовое поведение.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VpnService vpnService;
  late AuthService authService;
  late StorageService storageService;
  late CacheService cacheService;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    storageService = StorageService();
    await storageService.initialize();
    cacheService = CacheService();
    await cacheService.initialize();
  });

  Future<void> prefillServersCache() async {
    const serverJson = {
      'id': 1,
      'name': 'Test Server',
      'country': 'RU',
      'city': 'Moscow',
      'ip_address': '1.2.3.4',
      'wireguard_port': 443,
      'is_active': true,
      'current_users': 0,
      'max_users': 100,
      'ping_ms': 50.0,
      'supported_protocols': ['xray_vless'],
    };
    await cacheService.setString(
      'cached_servers',
      jsonEncode([serverJson]),
      ttl: const Duration(hours: 24),
    );
  }

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_connectivityChannel, (call) async {
      if (call.method == 'check') return <String>['wifi'];
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_vpnChannel, (call) async {
      switch (call.method) {
        case 'requestPermission':
          return true;
        case 'getStatus':
          return {'connected': false};
        case 'connect':
          return true;
        case 'disconnect':
          return true;
        case 'isXrayAvailable':
          return true;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_connectivityChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_vpnChannel, null);
    vpnService.dispose();
  });

  Widget buildTestWidget() {
    final fakeApi = FakeApiClient();
    fakeApi.stubGetResponse = Response(
      requestOptions: RequestOptions(path: '/vpn/servers'),
      statusCode: 200,
      data: [
        {
          'id': 1,
          'name': 'Test Server',
          'country': 'RU',
          'city': 'Moscow',
          'ip_address': '1.2.3.4',
          'wireguard_port': 443,
          'is_active': true,
          'current_users': 0,
          'max_users': 100,
          'supported_protocols': ['xray_vless'],
          'wireguard_public_key': 'test_wg_public_key___________________',
        },
      ],
    );
    authService = _FakeAuthForTrialScreen();
    vpnService = VpnService(
      apiClient: fakeApi,
      logger: Logger(),
      cacheService: cacheService,
      storageService: storageService,
      errorHandler: ErrorHandler(),
      connectionLogger: ConnectionLogger(),
      authService: authService,
      skipInitialize: true,
    );

    return MaterialApp(
      locale: const Locale('ru'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<VpnService>.value(value: vpnService),
          ChangeNotifierProvider<AuthService>.value(value: authService),
        ],
        child: const TrialUnifiedScreen(),
      ),
    );
  }

  group('TrialUnifiedScreen', () {
    testWidgets('отображает заголовок «Тестовый период»', (tester) async {
      await prefillServersCache();
      await tester.pumpWidget(buildTestWidget());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // postFrameCallback: refreshServers с timeout 20s — дожимаем fake-async, затем отмена таймеров в dispose.
      await tester.pump(const Duration(seconds: 21));

      expect(find.text('Тестовый период'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('экран успешно строится', (tester) async {
      await prefillServersCache();
      await tester.pumpWidget(buildTestWidget());
      await tester.pump();
      await tester.pump(const Duration(seconds: 21));

      expect(find.byType(TrialUnifiedScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}

class _FakeAuthForTrialScreen extends AuthService {
  _FakeAuthForTrialScreen();

  @override
  String? get token => 'test_token';

  @override
  bool get hasActiveSubscription => false;

  /// Иначе _getTimerText(0) дергает Navigator к /trial-ended без маршрута в тесте.
  @override
  int? get trialSecondsLeft => 3600;

  @override
  Future<bool> ensureValidToken() async => true;

  @override
  Future<void> waitForTokenLoad() async {}

  @override
  Future<void> refreshUserStatus() async {}
}

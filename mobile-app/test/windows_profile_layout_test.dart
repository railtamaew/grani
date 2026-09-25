import 'dart:io';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:provider/provider.dart';
import 'package:mobile_app/core/session/locale_controller.dart';
import 'package:mobile_app/l10n/app_localizations.dart';
import 'package:mobile_app/models/user.dart';
import 'package:mobile_app/screens/bottom_sheet_profile.dart';
import 'package:mobile_app/services/auth_service.dart';
import 'package:mobile_app/services/vpn_service.dart';
import 'package:mobile_app/theme.dart';
import 'package:mobile_app/widgets/desktop_app_frame.dart';
import 'package:mobile_app/core/cache/cache_service.dart';
import 'package:mobile_app/core/errors/error_handler.dart';
import 'package:mobile_app/core/logger/logger.dart';
import 'package:mobile_app/core/storage/storage_service.dart';
import 'package:mobile_app/services/connection_logger.dart';
import 'support/fake_api_client.dart';

class _Auth extends Mock implements AuthService {}

class _Locale extends Mock implements LocaleController {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fonts = FontLoader('Montserrat');
    for (final weight in ['Light', 'Regular', 'Medium', 'SemiBold', 'Bold']) {
      final data = await rootBundle.load('assets/fonts/Montserrat-$weight.ttf');
      expect(data.getUint32(0), 0x00010000,
          reason:
              '$weight must be a TrueType font, not an HTML download page.');
      fonts.addFont(Future.value(data));
    }
    await fonts.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  for (final language in ['ru', 'en']) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('Windows menu fits $language at text scale $scale',
          (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 780);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final auth = _Auth(), locale = _Locale();
        when(() => auth.hasActiveSubscription).thenReturn(true);
        when(() => auth.trialSecondsLeft).thenReturn(0);
        when(() => auth.subscriptionExpiresAt).thenReturn(DateTime(2028, 8, 4));
        when(() => auth.subscriptionStartedAt).thenReturn(DateTime(2026, 8, 4));
        when(() => auth.subscriptionPlanName).thenReturn('Premium');
        when(() => auth.maxDevices).thenReturn(5);
        when(() => auth.user).thenReturn(User(
            id: 'preview',
            email: 'account@example.com',
            isEmailVerified: true,
            createdAt: DateTime(2026),
            isBlocked: false));
        when(() => auth.token).thenReturn('preview-token');
        final api = FakeApiClient()
          ..stubGetResponse = Response(
              requestOptions: RequestOptions(path: '/vpn/devices'),
              statusCode: 200,
              data: [
                {'device_id': 'one'},
                {'device_id': 'two'},
                {'device_id': 'three'}
              ]);
        final vpn = VpnService(
            apiClient: api,
            logger: Logger(),
            cacheService: CacheService(),
            storageService: StorageService(),
            errorHandler: ErrorHandler(),
            connectionLogger: ConnectionLogger(),
            authService: auth,
            skipInitialize: true);
        addTearDown(vpn.dispose);
        const connectivity =
            MethodChannel('dev.fluttercommunity.plus/connectivity');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(connectivity, (_) async => ['wifi']);
        addTearDown(
            () => messenger.setMockMethodCallHandler(connectivity, null));
        when(() => locale.locale).thenReturn(Locale(language));
        final screenshot = GlobalKey();
        await tester.pumpWidget(MultiProvider(
            providers: [
              ChangeNotifierProvider<AuthService>.value(value: auth),
              ChangeNotifierProvider<VpnService>.value(value: vpn),
              ChangeNotifierProvider<LocaleController>.value(value: locale),
            ],
            child: RepaintBoundary(
                key: screenshot,
                child: MaterialApp(
                  theme: GraniTheme.theme,
                  debugShowCheckedModeBanner: false,
                  locale: Locale(language),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: DesktopAppFrame(child: child!),
                  ),
                  home: Scaffold(
                      body: Builder(
                          builder: (context) => TextButton(
                              onPressed: () => showProfileDrawer(context),
                              child: const Text('Open profile')))),
                ))));
        await tester.tap(find.text('Open profile'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        for (final label in language == 'ru'
            ? ['Email', 'Раздельный туннель', 'Написать в поддержку']
            : ['Email']) {
          final matches = find.text(label);
          expect(matches, findsOneWidget);
          final paragraph = tester.renderObject<RenderParagraph>(matches);
          expect(paragraph.didExceedMaxLines, isFalse, reason: label);
        }
        await tester.runAsync(() async {
          final boundary = screenshot.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/qa/profile-$language-$scale.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.drag(
            find.byType(SingleChildScrollView).first, const Offset(0, -1000));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
    }
  }
}

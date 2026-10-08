import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golden_toolkit/golden_toolkit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:provider/provider.dart';
import 'package:mobile_app/services/auth_service.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_api.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_controller.dart';
import 'package:mobile_app/tv/tv_home_view.dart';
import 'package:mobile_app/tv/tv_sign_in_screen.dart';
import 'package:mobile_app/tv/tv_selection_dialog.dart';
import 'package:mobile_app/tv/tv_checkout_dialog.dart';
import 'package:mobile_app/tv/tv_ui.dart';
import 'package:mobile_app/l10n/app_localizations.dart';
import 'package:mobile_app/widgets/button_connection.dart';
import 'package:mobile_app/theme.dart';

class MockController extends Mock implements SimpleVpnController {}

class MockAuth extends Mock implements AuthService {}

final captureKey = GlobalKey();
Widget app(Widget child, {String locale = 'ru', double scale = 1}) =>
    MaterialApp(
      theme: tvTheme(),
      locale: Locale(locale),
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates
      ],
      home: RepaintBoundary(
          key: captureKey,
          child: MediaQuery(
              data: MediaQueryData(
                  size: const Size(960, 540),
                  textScaler: TextScaler.linear(scale)),
              child: child)),
    );
Future<void> screenshot(WidgetTester tester, String name) async {
  // Raster assets finish decoding on real time, outside the fake test clock.
  await tester.runAsync(() async {
    final context = captureKey.currentContext!;
    for (final image in tester.widgetList<Image>(find.byType(Image))) {
      await precacheImage(image.image, context);
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
  });
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    final boundary =
        captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final picture = await boundary.toImage();
    final data = await picture.toByteData(format: ui.ImageByteFormat.png);
    final path = File('qa/tv-$name.png');
    await path.parent.create(recursive: true);
    await path.writeAsBytes(data!.buffer.asUint8List());
    picture.dispose();
  });
}

Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() {});
  for (final scale in [1.0, 1.3]) {
    testWidgets(
        'mobile connection artwork responds once to remote OK and keeps heading visible at scale $scale',
        (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final vpn = MockController();
      when(() => vpn.state).thenReturn(SimpleVpnState.disconnected);
      when(() => vpn.connectionProgressPercent).thenReturn(null);
      when(() => vpn.isBusy).thenReturn(false);
      when(() => vpn.isConnected).thenReturn(false);
      when(() => vpn.isConnecting).thenReturn(false);
      when(() => vpn.isRestoringNativeState).thenReturn(false);
      when(() => vpn.error).thenReturn(null);
      when(() => vpn.networkNotice).thenReturn(null);
      when(() => vpn.selectedServer).thenReturn(SimpleVpnServer.fromJson(
          {'id': 1, 'name': 'Нидерланды · Амстердам'}));
      when(() => vpn.selectedProtocol)
          .thenReturn(SimpleVpnProtocol.fromJson({'id': 'graniwg'}));
      when(() => vpn.toggle(source: any(named: 'source')))
          .thenAnswer((_) async {});
      var servers = 0, protocols = 0;
      Widget home() => app(
          TvHomeView(
              controller: vpn,
              title: 'VPN отключён',
              subtitle: 'Одно нажатие — и ваш интернет защищён.',
              serverLabel: 'Амстердам, Нидерланды',
              protocolLabel: 'GRANI WG',
              protocolIcon: Icons.shield_outlined,
              // Production preserves this space while the stage caption is hidden.
              connectionTimeline: const SizedBox(height: 34),
              onServer: () => servers++,
              onProtocol: () => protocols++),
          scale: scale);
      await tester.pumpWidget(home());
      await tester.pumpAndSettle();
      await screenshot(tester, 'home');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      verify(() => vpn.toggle(source: 'tv_remote')).called(1);
      expect(find.byType(ButtonConnection), findsOneWidget);
      expect(tvTheme().brightness, Brightness.light);
      expect(tvTheme().colorScheme.primary, GraniTheme.primaryText);
      when(() => vpn.state).thenReturn(SimpleVpnState.disconnecting);
      when(() => vpn.isBusy).thenReturn(true);
      await tester.pumpWidget(home());
      // Disconnecting deliberately animates until the native stop completes.
      await tester.pump(const Duration(milliseconds: 150));
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 150));
      verifyNever(() => vpn.toggle(source: 'tv_remote'));
      when(() => vpn.state).thenReturn(SimpleVpnState.disconnected);
      when(() => vpn.isBusy).thenReturn(false);
      await tester.pumpWidget(home());
      await tester.pumpAndSettle();
      await key(tester, LogicalKeyboardKey.select);
      verify(() => vpn.toggle(source: 'tv_remote')).called(1);
      await key(tester, LogicalKeyboardKey.arrowDown);
      final homeScroll = tester.state<ScrollableState>(find
          .descendant(
              of: find.byType(TvHomeView), matching: find.byType(Scrollable))
          .first);
      expect(homeScroll.position.maxScrollExtent, closeTo(0, 0.01));
      expect(
          tester.getTopLeft(find.text('VPN отключён')).dy,
          greaterThanOrEqualTo(
              tester.getTopLeft(find.byType(SingleChildScrollView)).dy));
      await key(tester, LogicalKeyboardKey.select);
      expect(servers + protocols, 1);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('email validation, code resend cooldown, Back returns to welcome',
      (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = MockAuth();
    when(() => auth.secondsUntilCodeResend).thenReturn(30);
    when(() => auth.sendCode('user@example.test', omitGlobalLoadingState: true))
        .thenAnswer((_) async => true);
    await tester.pumpWidget(ChangeNotifierProvider<AuthService>.value(
        value: auth, child: app(const TvSignInScreen())));
    await tester.pumpAndSettle();
    await screenshot(tester, 'welcome');
    await key(tester, LogicalKeyboardKey.select);
    expect(find.byKey(const ValueKey('tv-email')), findsOneWidget);
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.select);
    expect(tester.widget<TvNotice>(find.byType(TvNotice)).message,
        'Введите email');
    verifyNever(() => auth.sendCode(any(), omitGlobalLoadingState: true));
    await tester.enterText(
        find.byKey(const ValueKey('tv-email')), 'user@example.test');
    await tester.tap(find.text('Отправить код'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tv-code')), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Новый код через 30 с'))
            .onPressed,
        isNull);
    await screenshot(tester, 'code');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tv-email')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Продолжить с email'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('long selector scrolls with remote and restores focus on close',
      (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var picked = -1;
    await tester.pumpWidget(app(Builder(
        builder: (context) => TvPage(
            title: 'GRANI',
            child: TvButton(
                label: 'Выбор сервера',
                autofocus: true,
                onPressed: () async {
                  picked = await showTvSelection<int>(
                          context: context,
                          title: 'Серверы',
                          options: List.generate(20, (i) => i),
                          label: (i) => 'Сервер $i',
                          selected: (i) => i == 0) ??
                      -1;
                })))));
    await tester.pumpAndSettle();
    await key(tester, LogicalKeyboardKey.select);
    for (var i = 0; i < 9; i++) {
      await key(tester, LogicalKeyboardKey.arrowDown);
    }
    await key(tester, LogicalKeyboardKey.select);
    expect(picked, 9);
    expect(find.text('Серверы'), findsNothing);
    await key(tester, LogicalKeyboardKey.select);
    expect(find.text('Серверы'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Серверы'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('selector focuses the saved server beyond the first viewport',
      (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var picked = -1;
    await tester.pumpWidget(app(Builder(
        builder: (context) => TvButton(
            label: 'Open',
            autofocus: true,
            onPressed: () async {
              picked = await showTvSelection<int>(
                      context: context,
                      title: 'Серверы',
                      options: List.generate(20, (i) => i),
                      label: (i) => 'Сервер $i',
                      selected: (i) => i == 17) ??
                  -1;
            }))));
    await tester.pumpAndSettle();
    await key(tester, LogicalKeyboardKey.select);
    expect(find.text('Сервер 17').hitTestable(), findsOneWidget);
    await key(tester, LogicalKeyboardKey.select);
    expect(picked, 17);
    expect(tester.takeException(), isNull);
  });
  for (final locale in ['ru', 'en']) {
    testWidgets(
        'checkout QR fits 960x540 in $locale and OK only checks payment',
        (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var checks = 0;
      await tester.pumpWidget(app(
          TvCheckoutDialog(
              uri: Uri.parse(
                  'https://granilink.com/ru/checkout#handoff=test-fixture'),
              onCheck: () => checks++),
          locale: locale));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await screenshot(tester, 'checkout-$locale');
      await key(tester, LogicalKeyboardKey.select);
      expect(checks, 1);
    });
  }
}

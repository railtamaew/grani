import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/tv/tv_split_tunnel_screen.dart';
import 'package:mobile_app/tv/tv_ui.dart';

void main() {
  const channel = MethodChannel('com.granivpn.mobile/vpn');
  List<String> saved = [];
  String mode = 'exclude';
  bool? connected = false;
  int writes = 0;
  bool failPackages = false;
  setUp(() {
    saved = ['hidden.package'];
    mode = 'exclude';
    connected = false;
    writes = 0;
    failPackages = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getInstalledApps':
          return [
            {'package': 'tv.youtube', 'label': 'YouTube'},
            {'package': 'tv.player', 'label': 'Player'}
          ];
        case 'getSplitTunnelMode':
          return mode;
        case 'getSplitTunnelExcludedApps':
          if (failPackages) throw PlatformException(code: 'READ_FAILED');
          return saved;
        case 'getAmneziaWgStatus':
        case 'getStatus':
          return {'connected': connected};
        case 'setSplitTunnelMode':
          mode = (call.arguments as Map)['mode'] as String;
          writes++;
          return null;
        case 'setSplitTunnelExcludedApps':
          saved = List<String>.from(call.arguments as List);
          writes++;
          return null;
      }
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: tvTheme(),
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Builder(
            builder: (context) => TvButton(
                label: 'Open',
                onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                        builder: (_) => const TvSplitTunnelScreen()))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('saves TV apps and preserves hidden existing packages',
      (tester) async {
    await open(tester);
    expect(find.text('hidden.package'), findsOneWidget);
    await tester.tap(find.text('YouTube'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(saved, ['hidden.package', 'tv.youtube']);
    expect(writes, 2);
    expect(find.text('Open'), findsOneWidget);
  });
  testWidgets('never changes routing while VPN is active', (tester) async {
    connected = true;
    await open(tester);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Сохранить'))
            .onPressed,
        isNull);
    expect(writes, 0);
  });
  testWidgets('rechecks native status at Save and blocks unknown status',
      (tester) async {
    await open(tester);
    connected = null;
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(find.text('Настройки не сохранились. Попробуйте ещё раз.'),
        findsOneWidget);
  });
  for (final failure in ['packages', 'status']) {
    testWidgets('failed $failure load cannot erase rules and can be retried',
        (tester) async {
      failPackages = failure == 'packages';
      connected = failure == 'status' ? null : false;
      await open(tester);
      expect(find.text('Не удалось загрузить настройки.'), findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Сохранить'))
              .onPressed,
          isNull);
      expect(saved, ['hidden.package']);
      expect(writes, 0);
      failPackages = false;
      connected = false;
      await tester.tap(find.text('Повторить'));
      await tester.pumpAndSettle();
      expect(find.text('hidden.package'), findsOneWidget);
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(saved, ['hidden.package']);
      expect(find.text('Open'), findsOneWidget);
    });
  }
}

import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import '../lib/models/profile_access_snapshot.dart';
import '../lib/widgets/profile/grani_menu_sections.dart';
import '../lib/widgets/profile/profile_ui_kit.dart';

final now = DateTime.utc(2026, 10, 5, 9);
ProfileAccessSnapshot snapshot(String state) =>
    ProfileAccessSnapshot.fromPayload({
      'trialSecondsLeft': state == 'gift' || state == 'trial' ? 2 * 86400 : 0,
      'trialTotalSeconds': state == 'gift' ? 7 * 86400 : 3 * 86400,
      'subscription_started_at': '2026-10-05T09:00:00Z',
      'bonus_starts_at': '2026-10-05T09:00:00Z',
      'paid_access_elapsed_seconds': state == 'paid' ? 90 * 86400 : 0,
      'hasActiveSubscription': state == 'paid' || state == 'bonus',
      'trialExperimentVariant':
          state == 'gift' ? 'referral_168h' : 'variant_72h',
      'subscription_source': state == 'bonus' ? 'referral_bonus' : 'wata_sbp',
      'subscription_expires_at': '2026-11-05T09:00:00Z',
      'subscription_auto_renew': false,
      'bonus_seconds': state == 'trial' ? 259200 : 0,
    }, now: now);

Widget menu(
        {String state = 'trial',
        void Function(String)? tap,
        int? count = 1,
        bool error = false}) =>
    GraniMenuSections(
        access: snapshot(state),
        now: now,
        email: 'long.account.name@example.com',
        version: '57 (1.0.57)',
        language: 'Русский / English',
        deviceCount: count,
        deviceError: error,
        onPlan: () => tap?.call('plan'),
        onShare: () => tap?.call('share'),
        onReceive: () => tap?.call('receive'),
        onBonuses: () => tap?.call('bonuses'),
        onLanguage: () => tap?.call('language'),
        onSplitTunnel: () => tap?.call('split'),
        onDevices: () => tap?.call('devices'),
        onNotifications: () => tap?.call('notifications'),
        onSupport: () => tap?.call('support'),
        onCopyEmail: () => tap?.call('email'),
        onCopyVersion: () => tap?.call('version'));

Widget harness(Widget child,
        {String language = 'ru',
        double width = 364,
        double scale = 1,
        bool preview = false}) =>
    MaterialApp(
        locale: Locale(language),
        supportedLocales: const [Locale('ru'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: MediaQuery(
            data: MediaQueryData(
                size: Size(width, 880),
                devicePixelRatio: 2,
                textScaler: TextScaler.linear(scale),
                disableAnimations: true),
            child: Scaffold(
                body: Align(
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                        width: width,
                        child: SingleChildScrollView(
                            child: RepaintBoundary(
                                key: const ValueKey('menu-preview'),
                                child: ColoredBox(
                                    color: const Color(0xFFF7F9FA),
                                    child: Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: child)))))))));

Future<void> preview(WidgetTester tester, String name) async {
  final directory = Platform.environment['GRANI_MENU_UX_PREVIEW_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('menu-preview')));
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await initializeDateFormatting('ru');
    final text = FontLoader('Montserrat')
      ..addFont(rootBundle.load('assets/fonts/GraniGiftMontserrat-Regular.ttf'))
      ..addFont(
          rootBundle.load('assets/fonts/GraniGiftMontserrat-SemiBold.ttf'))
      ..addFont(rootBundle.load('assets/fonts/GraniGiftMontserrat-Bold.ttf'));
    final gift = FontLoader('GraniGiftMontserrat')
      ..addFont(rootBundle.load('assets/fonts/GraniGiftMontserrat-Bold.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait([text.load(), gift.load(), icons.load()]);
  });
  for (final language in ['ru', 'en']) {
    for (final width in [282.0, 364.0]) {
      for (final scale in [1.0, 1.4]) {
        testWidgets('menu groups and all text fit $language $width $scale',
            (tester) async {
          await tester.pumpWidget(
              harness(menu(), language: language, width: width, scale: scale));
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 150)));
          await tester.pump();
          final positions = [
            for (final section in [
              'access',
              'gifts',
              'settings',
              'help',
              'account'
            ])
              tester
                  .getTopLeft(find.byKey(ValueKey('profile-section-$section')))
                  .dy
          ];
          expect(positions, orderedEquals([...positions]..sort()));
          expect(
              find.textContaining(
                  language == 'ru' ? 'Привязано 1 из 5' : '1 of 5 linked'),
              findsOneWidget);
          expect(find.text('Trial access'),
              language == 'ru' ? findsNothing : findsOneWidget);
          expect(find.textContaining('диагностик'), findsNothing);
          expect(find.textContaining('diagnostic'), findsNothing);
          expect(tester.takeException(), isNull);
          if (width == 364 && scale == 1)
            await preview(tester, 'menu-$language');
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
    for (final state in ['paid', 'gift', 'bonus', 'ended']) {
      testWidgets(
          'access $state has appropriate localized label and action $language',
          (tester) async {
        await tester.pumpWidget(harness(menu(state: state),
            language: language, width: 282, scale: 1.4));
        final label = {
          'paid': ['Оплаченный доступ', 'Paid access'],
          'gift': ['Подарочный доступ', 'Gift access'],
          'bonus': ['Бонусный доступ', 'Bonus access'],
          'ended': ['Доступ не активен', 'Access is inactive']
        }[state]!;
        expect(find.text(label[language == 'ru' ? 0 : 1]), findsOneWidget);
        expect(
            find.text(state == 'paid'
                ? language == 'ru'
                    ? 'Продлить доступ'
                    : 'Extend access'
                : language == 'ru'
                    ? 'Выбрать тариф'
                    : 'Choose a plan'),
            findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
  testWidgets('all actions remain distinct; copy uses copy icons',
      (tester) async {
    final taps = <String>[];
    await tester.pumpWidget(harness(menu(tap: taps.add)));
    for (final pair in {
      'profile-access-plan': 'plan',
      'profile-gift-share': 'share',
      'profile-gift-receive': 'receive',
      'profile-gift-bonuses': 'bonuses',
      'profile-language': 'language',
      'profile-split-tunnel': 'split',
      'profile-devices': 'devices',
      'profile-notifications': 'notifications',
      'profile-support': 'support',
      'profile-copy-email': 'email',
      'profile-copy-version': 'version'
    }.entries) {
      final row = find.byKey(ValueKey(pair.key));
      await tester.ensureVisible(row);
      expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
      await tester.tap(row);
      await tester.pump();
    }
    expect(taps, [
      'plan',
      'share',
      'receive',
      'bonuses',
      'language',
      'split',
      'devices',
      'notifications',
      'support',
      'email',
      'version'
    ]);
    for (final key in ['profile-copy-email', 'profile-copy-version']) {
      expect(
          tester
              .widget<GraniSectionRow>(find.byKey(ValueKey(key)))
              .trailingIcon,
          Icons.content_copy);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('device loading/error never pretends zero devices are connected',
      (tester) async {
    await tester.pumpWidget(harness(menu(count: null)));
    expect(find.text('Загружаем список…'), findsOneWidget);
    expect(find.textContaining('Привязано 0'), findsNothing);
    await tester.pumpWidget(harness(menu(error: true)));
    expect(find.text('Не удалось обновить список'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('device limits and copy accessibility labels remain explicit',
      (tester) async {
    await tester.pumpWidget(harness(menu(count: 5)));
    expect(find.textContaining('Лимит достигнут'), findsOneWidget);
    expect(
        tester
            .widget<GraniSectionRow>(
                find.byKey(const ValueKey('profile-copy-email')))
            .semanticLabel,
        'Скопировать почту');
    await tester.pumpWidget(harness(menu(count: 6)));
    expect(find.textContaining('Лимит превышен'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('Google Play auto renewal retains manage action and source',
      (tester) async {
    final access = ProfileAccessSnapshot.fromPayload({
      'hasActiveSubscription': true,
      'subscription_source': 'google_play',
      'subscription_expires_at': '2026-11-05T09:00:00Z',
      'subscription_auto_renew': true
    }, now: now);
    await tester.pumpWidget(
        harness(GraniAccessCard(access: access, now: now, onPlan: () {})));
    expect(find.text('Управлять подпиской'), findsOneWidget);
    expect(find.text('Google Play · Автопродление включено'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('unknown cache does not promise trial or an invented date',
      (tester) async {
    await tester.pumpWidget(harness(GraniAccessCard(
        access: ProfileAccessSnapshot(capturedAt: now),
        now: now,
        onPlan: () {})));
    expect(find.text('Статус уточняется'), findsOneWidget);
    expect(find.textContaining('До '), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

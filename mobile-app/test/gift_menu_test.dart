import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/widgets/grani_gift_art.dart';
import '../lib/widgets/profile/grani_gift_section.dart';
import '../lib/widgets/profile/profile_ui_kit.dart';

Widget harness(
  Widget child, {
  String language = 'ru',
  double width = 364,
  double textScale = 1,
  bool reducedMotion = false,
}) => MaterialApp(
  locale: Locale(language),
  supportedLocales: const [Locale('ru'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: MediaQuery(
    data: MediaQueryData(
      size: Size(width, 880),
      devicePixelRatio: 3,
      textScaler: TextScaler.linear(textScale),
      disableAnimations: reducedMotion,
    ),
    child: Scaffold(
      body: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: width,
          child: RepaintBoundary(
            key: const ValueKey('gift-preview'),
            child: child,
          ),
        ),
      ),
    ),
  ),
);

Future<void> decodeArtwork(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 150)),
  );
  await tester.pump();
}

Future<void> savePreview(WidgetTester tester, String name) async {
  final directory = Platform.environment['GRANI_GIFT_MENU_PREVIEW_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('gift-preview')),
    );
    final image = await boundary.toImage(pixelRatio: 3);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File(
      '$directory/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final menu = FontLoader('Montserrat')
      ..addFont(rootBundle.load('assets/fonts/GraniGiftMontserrat-Regular.ttf'))
      ..addFont(
        rootBundle.load('assets/fonts/GraniGiftMontserrat-SemiBold.ttf'),
      )
      ..addFont(rootBundle.load('assets/fonts/GraniGiftMontserrat-Bold.ttf'));
    final gift = FontLoader('GraniGiftMontserrat')
      ..addFont(rootBundle.load('assets/fonts/GraniGiftMontserrat-Bold.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait([menu.load(), gift.load(), icons.load()]);
  });
  for (final language in ['ru', 'en']) {
    for (final width in [320.0, 364.0]) {
      for (final scale in [1.0, 1.4]) {
        testWidgets('one gift card $language width$width scale$scale', (
          tester,
        ) async {
          await tester.pumpWidget(
            harness(
              GraniGiftSection(
                onShare: () {},
                onReceive: () {},
                onBonuses: () {},
              ),
              language: language,
              width: width,
              textScale: scale,
              reducedMotion: true,
            ),
          );
          await decodeArtwork(tester);
          expect(find.byType(GraniSectionCard), findsOneWidget);
          expect(find.byType(GraniGiftArt), findsOneWidget);
          expect(
            find.text(language == 'ru' ? 'Делитесь GRANI.' : 'Share GRANI.'),
            findsOneWidget,
          );
          expect(
            find.text(
              language == 'ru'
                  ? '7 дней другу, а вам 3!'
                  : '7 days for your friend, 3 for you!',
            ),
            findsOneWidget,
          );
          expect(
            find.text(language == 'ru' ? 'Мне подарили' : 'Receive a gift'),
            findsOneWidget,
          );
          expect(
            find.text(language == 'ru' ? 'Мои бонусы' : 'My bonuses'),
            findsOneWidget,
          );
          for (final key in [
            'profile-gift-share',
            'profile-gift-receive',
            'profile-gift-bonuses',
          ]) {
            final row = find.byKey(ValueKey(key));
            expect(
              find.ancestor(
                of: row,
                matching: find.byKey(const ValueKey('profile-gifts-card')),
              ),
              findsOneWidget,
            );
            expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
          }
          expect(tester.takeException(), isNull);
          if (width == 364 && scale == 1)
            await savePreview(tester, 'gift-menu-$language');
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
    testWidgets('all gift actions remain independent $language', (
      tester,
    ) async {
      final taps = <String>[];
      await tester.pumpWidget(
        harness(
          GraniGiftSection(
            onShare: () => taps.add('share'),
            onReceive: () => taps.add('receive'),
            onBonuses: () => taps.add('bonuses'),
          ),
          language: language,
          reducedMotion: true,
        ),
      );
      await decodeArtwork(tester);
      for (final key in [
        'profile-gift-share',
        'profile-gift-receive',
        'profile-gift-bonuses',
      ]) {
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pump();
      }
      expect(taps, ['share', 'receive', 'bonuses']);
      await tester.pumpWidget(const SizedBox.shrink());
    });
    testWidgets('same artwork actually animates in $language', (tester) async {
      await tester.pumpWidget(
        harness(const GraniGiftArt(size: 72), language: language),
      );
      await decodeArtwork(tester);
      expect(find.byType(RawImage), findsOneWidget);
      final first = tester.widget<RawImage>(find.byType(RawImage)).image;
      expect(first, isNotNull);
      expect(find.text(language == 'ru' ? '7 дней' : '7 days'), findsOneWidget);
      // This bundled animation holds its closed-gift frame for 680ms.
      await tester.pump(const Duration(milliseconds: 700));
      await decodeArtwork(tester);
      expect(
        identical(first, tester.widget<RawImage>(find.byType(RawImage)).image),
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('reduced motion retains original artwork without advancing', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        const GraniGiftArt(size: 72),
        language: 'en',
        reducedMotion: true,
      ),
    );
    await decodeArtwork(tester);
    final first = tester.widget<RawImage>(find.byType(RawImage)).image;
    await tester.pump(const Duration(seconds: 1));
    await decodeArtwork(tester);
    expect(
      identical(first, tester.widget<RawImage>(find.byType(RawImage)).image),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('receipt artwork stays static even when motion is enabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(const GraniGiftArt(size: 72, animate: false), language: 'ru'),
    );
    await decodeArtwork(tester);
    final first = tester.widget<RawImage>(find.byType(RawImage)).image;
    expect(first, isNotNull);
    await tester.pump(const Duration(seconds: 1));
    await decodeArtwork(tester);
    expect(
      identical(first, tester.widget<RawImage>(find.byType(RawImage)).image),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

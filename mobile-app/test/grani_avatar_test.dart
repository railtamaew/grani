import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/models/profile_access_snapshot.dart';
import 'package:mobile_app/widgets/grani_avatar.dart';
import 'package:mobile_app/widgets/profile/grani_access_avatar.dart';
import 'package:mobile_app/widgets/profile/access_avatar_policy.dart';

Future<void> loaded(WidgetTester tester, GraniAvatarType type) async {
  for (var i = 0; i < 60; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
    await tester.pump();
    if (find
        .byKey(ValueKey('grani-avatar-art-${type.name}'))
        .evaluate()
        .isNotEmpty) return;
  }
  fail('Avatar ${type.name} did not load');
}

Widget harness(Widget child,
        {bool reduced = false, AssetBundle? bundle, double dpr = 2}) =>
    MaterialApp(
        home: MediaQuery(
            data: MediaQueryData(
                size: const Size(800, 600),
                disableAnimations: reduced,
                devicePixelRatio: dpr),
            child: DefaultAssetBundle(
                bundle: bundle ?? rootBundle,
                child: Scaffold(body: Center(child: child)))));

double progress(WidgetTester tester, GraniAvatarType type) => (tester
        .widget<CustomPaint>(
            find.byKey(ValueKey('grani-avatar-art-${type.name}')))
        .painter as dynamic)
    .progress
    .value as double;

class FaultBundle extends CachingAssetBundle {
  bool fail = true;
  int attempts = 0;
  @override
  Future<ByteData> load(String key) => rootBundle.load(key);
  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    attempts++;
    if (fail) throw StateError('Synthetic asset failure');
    return rootBundle.loadString(key);
  }
}

class DeferredBundle extends CachingAssetBundle {
  final first = Completer<String>();
  int calls = 0;
  @override
  Future<ByteData> load(String key) => rootBundle.load(key);
  @override
  Future<String> loadString(String key, {bool cache = true}) {
    if (++calls == 1) return first.future;
    return rootBundle.loadString(key, cache: false);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('Montserrat')
      ..addFont(
          rootBundle.load('assets/fonts/GraniGiftMontserrat-Regular.ttf'));
    await font.load();
  });
  setUp(() => rootBundle.evict('assets/grani_avatars/manifest.json'));
  final now = DateTime.utc(2026, 10, 6);
  ProfileAccessSnapshot facts(int? seconds,
          {bool paid = false, String? source, String? accountKey}) =>
      ProfileAccessSnapshot(
          capturedAt: now,
          known: true,
          active: paid,
          source: source,
          paidElapsedSeconds: seconds,
          accountKey: accountKey,
          subscriptionExpiresAt: DateTime.utc(2027, 10, 6));
  test('six exact earned levels come from past server seconds', () {
    for (final row in <int, GraniAvatarType>{
      0: GraniAvatarType.iskra,
      1: GraniAvatarType.guide,
      30 * 86400 - 1: GraniAvatarType.guide,
      30 * 86400: GraniAvatarType.navigator,
      90 * 86400 - 1: GraniAvatarType.navigator,
      90 * 86400: GraniAvatarType.keeper,
      180 * 86400 - 1: GraniAvatarType.keeper,
      180 * 86400: GraniAvatarType.master,
      360 * 86400: GraniAvatarType.master,
      365 * 86400 - 1: GraniAvatarType.master,
      365 * 86400: GraniAvatarType.legend,
    }.entries) {
      expect(accessAvatarType(facts(row.key), now), row.value);
      expect(
          accessAvatarType(facts(row.key), now.add(const Duration(days: 500))),
          row.value);
    }
    expect(accessAvatarType(facts(0, paid: true, source: 'wata_sbp'), now),
        GraniAvatarType.guide);
    expect(
        accessAvatarType(facts(null, paid: true, source: 'google_play'), now),
        GraniAvatarType.guide);
    expect(accessAvatarType(facts(null), now), isNull);
    expect(
        accessAvatarType(facts(0, paid: true, source: 'referral_bonus'), now),
        GraniAvatarType.iskra);
    expect(accessAvatarType(facts(null, paid: true), now), isNull);
    expect(accessAvatarType(facts(180 * 86400), now), GraniAvatarType.master);
  });
  for (final type in GraniAvatarType.values) {
    testWidgets('${type.name} waits for a tap and ignores repeated taps',
        (tester) async {
      var taps = 0;
      await tester
          .pumpWidget(harness(GraniAvatar(type: type, onTap: () => taps++)));
      await loaded(tester, type);
      await tester.pump(const Duration(seconds: 3));
      expect(progress(tester, type), 0);
      await tester.tap(find.byType(GraniAvatar));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(progress(tester, type), greaterThan(0));
      for (var i = 0; i < 8; i++) {
        await tester.tap(find.byType(GraniAvatar));
        await tester.pump();
      }
      expect(taps, 1);
      await tester.pump(const Duration(seconds: 3));
      expect(progress(tester, type), 0);
      await tester.tap(find.byType(GraniAvatar));
      await tester.pump();
      expect(taps, 2);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('reduced motion removes the reaction semantics and tap',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(harness(
        const GraniAvatar(
            type: GraniAvatarType.guide,
            semanticLabel: 'Guide avatar',
            semanticHint: 'Play reaction'),
        reduced: true));
    await loaded(tester, GraniAvatarType.guide);
    final node = tester.getSemantics(find.byType(GraniAvatar));
    expect(node.hasFlag(ui.SemanticsFlag.isButton), false);
    expect(node.getSemanticsData().hasAction(ui.SemanticsAction.tap), false);
    expect(node.getSemanticsData().hint, isEmpty);
    await tester.tap(find.byType(GraniAvatar));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(progress(tester, GraniAvatarType.guide), 0);
    semantics.dispose();
  });
  testWidgets('background stops and never resumes a pending gesture',
      (tester) async {
    await tester
        .pumpWidget(harness(const GraniAvatar(type: GraniAvatarType.guide)));
    await loaded(tester, GraniAvatarType.guide);
    await tester.tap(find.byType(GraniAvatar));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(progress(tester, GraniAvatarType.guide), 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 500));
    expect(progress(tester, GraniAvatarType.guide), 0);
  });
  testWidgets('asset failure is neutral, bounded and explicitly retryable',
      (tester) async {
    final bundle = FaultBundle();
    Widget avatar(int retry) => harness(
        GraniAvatar(
            type: GraniAvatarType.guide,
            retryToken: retry,
            placeholder: const Text('NEUTRAL')),
        bundle: bundle);
    await tester.pumpWidget(avatar(0));
    await tester.pumpAndSettle();
    expect(find.text('NEUTRAL'), findsOneWidget);
    expect(bundle.attempts, 1);
    await tester.pumpWidget(avatar(0));
    expect(bundle.attempts, 1);
    bundle.fail = false;
    await tester.pumpWidget(avatar(1));
    await loaded(tester, GraniAvatarType.guide);
    expect(bundle.attempts, 2);
    expect(progress(tester, GraniAvatarType.guide), 0);
    bundle.fail = true;
    await tester.pumpWidget(harness(
        const GraniAvatar(
            type: GraniAvatarType.legend, placeholder: Text('NEUTRAL')),
        bundle: bundle));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('grani-avatar-art-guide')), findsNothing);
    expect(find.text('NEUTRAL'), findsOneWidget);
  });
  testWidgets(
      'actual scroll visibility cancels movement; account key resets it',
      (tester) async {
    final scroll = ScrollController();
    Widget page(String account) => harness(SingleChildScrollView(
        controller: scroll,
        child: Column(children: [
          GraniAccessAvatar(
              access: facts(1, accountKey: account),
              kind: ProfileAccessKind.paid,
              accountKey: account),
          const SizedBox(height: 2500)
        ])));
    await tester.pumpWidget(page('one'));
    await loaded(tester, GraniAvatarType.guide);
    await tester.pump();
    await tester.tap(find.byType(GraniAvatar));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(progress(tester, GraniAvatarType.guide), greaterThan(0));
    scroll.jumpTo(1000);
    await tester.pump();
    await tester.pump();
    expect(
        tester.widget<GraniAvatar>(find.byType(GraniAvatar)).isVisible, false);
    expect(progress(tester, GraniAvatarType.guide), 0);
    scroll.jumpTo(0);
    await tester.pump();
    await tester.pump();
    expect(progress(tester, GraniAvatarType.guide), 0);
    final previous = tester.state(find.byType(GraniAvatar));
    await tester.pumpWidget(page('two'));
    expect(identical(previous, tester.state(find.byType(GraniAvatar))), false);
    await loaded(tester, GraniAvatarType.guide);
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
  });
  testWidgets('41 Flutter-rendered phases fit each circular viewport',
      (tester) async {
    final out = Directory('qa/avatar-frames');
    out.createSync(recursive: true);
    var checked = 0;
    for (final type in GraniAvatarType.values) {
      final key = GlobalKey();
      for (var frame = 0; frame <= 40; frame++) {
        await tester.pumpWidget(harness(
            RepaintBoundary(
                key: key,
                child: SizedBox.square(
                    dimension: 96,
                    child: Center(
                        child: GraniAvatar(
                            type: type,
                            size: 58,
                            animateOnTap: false,
                            motionEnabled: false,
                            previewProgress: frame / 40)))),
            dpr: 3));
        await loaded(tester, type);
        await tester.pump();
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 3);
          final raw =
              await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          final data = raw!.buffer.asUint8List();
          var outside = 0;
          for (var y = 0; y < image.height; y++) {
            for (var x = 0; x < image.width; x++) {
              final dx = x + .5 - image.width / 2,
                  dy = y + .5 - image.height / 2;
              if (dx * dx + dy * dy > 87 * 87 &&
                  data[(y * image.width + x) * 4 + 3] > 16) outside++;
            }
          }
          expect(outside, 0,
              reason: '${type.name} phase $frame exceeds its circle');
          if (frame % 10 == 0) {
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            await File('${out.path}/${type.name}-$frame.png')
                .writeAsBytes(png!.buffer.asUint8List());
          }
          image.dispose();
        });
        checked++;
      }
      await tester.pumpWidget(const SizedBox());
    }
    File('qa/avatar-geometry.txt')
        .writeAsStringSync('$checked phases checked on Flutter at DPR3');
  });

  testWidgets('late loading response cannot restore the previous character',
      (tester) async {
    final bundle = DeferredBundle();
    await tester.pumpWidget(harness(
        const GraniAvatar(type: GraniAvatarType.guide),
        bundle: bundle));
    await tester.pump();
    await tester.pumpWidget(harness(
        const GraniAvatar(type: GraniAvatarType.legend),
        bundle: bundle));
    await loaded(tester, GraniAvatarType.legend);
    await tester.runAsync(() async {
      bundle.first.complete(await rootBundle
          .loadString('assets/grani_avatars/manifest.json', cache: false));
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('grani-avatar-art-guide')), findsNothing);
    expect(
        find.byKey(const ValueKey('grani-avatar-art-legend')), findsOneWidget);
  });
  testWidgets('another route stops a retained menu avatar', (tester) async {
    await tester.pumpWidget(harness(GraniAccessAvatar(
        access: facts(1, accountKey: 'account'),
        kind: ProfileAccessKind.paid,
        accountKey: 'account')));
    await loaded(tester, GraniAvatarType.guide);
    await tester.pump();
    final clock = (tester
            .widget<CustomPaint>(
                find.byKey(const ValueKey('grani-avatar-art-guide')))
            .painter as dynamic)
        .progress as Animation<double>;
    await tester.tap(find.byType(GraniAvatar));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(clock.value, greaterThan(0));
    final nav = Navigator.of(tester.element(find.byType(GraniAccessAvatar)));
    unawaited(nav.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('NEXT')))));
    await tester.pumpAndSettle();
    expect(clock.value, 0);
    nav.pop();
    await tester.pumpAndSettle();
    expect(clock.value, 0);
  });
  testWidgets('local avatar switch keeps a neutral circle without badges',
      (tester) async {
    await tester.pumpWidget(harness(GraniAccessAvatar(
        access: facts(365 * 86400),
        kind: ProfileAccessKind.paid,
        charactersEnabled: false)));
    await tester.pumpAndSettle();
    expect(find.byType(GraniAvatar), findsNothing);
    expect(tester.getSize(find.byType(GraniAccessAvatar)), const Size(58, 58));
    expect(find.text('Premium'), findsNothing);
  });
  testWidgets('capture six circles and actual tap-stop-reduced-motion sequence',
      (tester) async {
    final folder = Directory('qa/avatar-motion');
    folder.createSync(recursive: true);
    final key = GlobalKey();
    var visible = true, reduced = false;
    Widget page() => harness(
        RepaintBoundary(
            key: key,
            child: SizedBox.square(
                dimension: 180,
                child: Center(
                    child: ClipOval(
                        child: GraniAvatar(
                            type: GraniAvatarType.guide,
                            size: 58,
                            isVisible: visible))))),
        reduced: reduced,
        dpr: 3);
    await tester.pumpWidget(page());
    await loaded(tester, GraniAvatarType.guide);
    for (var frame = 0; frame < 65; frame++) {
      if (frame == 1 ||
          frame == 3 ||
          frame == 16 ||
          frame == 27 ||
          frame == 35) {
        await tester.tap(find.byType(GraniAvatar));
        await tester.pump();
      }
      if (frame == 9) {
        visible = false;
        await tester.pumpWidget(page());
      }
      if (frame == 12) {
        visible = true;
        await tester.pumpWidget(page());
      }
      if (frame == 20) {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      }
      if (frame == 23) {
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      }
      if (frame == 25) {
        reduced = true;
        await tester.pumpWidget(page());
      }
      if (frame == 33) {
        reduced = false;
        await tester.pumpWidget(page());
      }
      await tester.pump(const Duration(milliseconds: 85));
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 3);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
                '${folder.path}/frame-${frame.toString().padLeft(3, '0')}.png')
            .writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
      if ([0, 9, 12, 20, 23, 25, 27, 33, 64].contains(frame)) {
        expect(progress(tester, GraniAvatarType.guide), 0,
            reason: 'idle frame $frame');
      }
    }
    final galleryKey = GlobalKey();
    final earned = [0, 1, 30 * 86400, 90 * 86400, 180 * 86400, 365 * 86400];
    await tester.pumpWidget(harness(
        RepaintBoundary(
            key: galleryKey,
            child: Container(
                color: const Color(0xFFF7F9FA),
                padding: const EdgeInsets.all(18),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  for (var i = 0; i < 6; i++)
                    Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          GraniAccessAvatar(
                              access: facts(earned[i]),
                              kind: i == 0
                                  ? ProfileAccessKind.trial
                                  : ProfileAccessKind.paid),
                          const SizedBox(height: 8),
                          Text(GraniAvatarType.values[i].name,
                              style: const TextStyle(
                                  fontFamily: 'Montserrat', fontSize: 12)),
                        ])),
                ]))),
        dpr: 3,
        reduced: true));
    for (final type in GraniAvatarType.values) {
      await loaded(tester, type);
    }
    await tester.runAsync(() async {
      final image = await (galleryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary)
          .toImage(pixelRatio: 3);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('qa/avatar-six-circles.png')
          .writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
    });
  });

  test('temporary metric failure retains only the same account confirmed rank',
      () {
    final original = ProfileAccessSnapshot.fromPayload({
      'hasActiveSubscription': true,
      'subscription_source': 'wata_sbp',
      'paid_access_elapsed_seconds': 365 * 86400,
    }, now: now, accountKey: 'one');
    final stored = ProfileAccessSnapshot.fromJson(original.toJson());
    final unknown = ProfileAccessSnapshot.fromPayload({
      'hasActiveSubscription': false,
      'paid_access_elapsed_seconds': null,
    }, now: now, accountKey: 'one', previous: stored);
    expect(accessAvatarType(unknown, now), GraniAvatarType.legend);
    expect(unknown.kindAt(now), ProfileAccessKind.ended);
    final another = ProfileAccessSnapshot.fromPayload({
      'hasActiveSubscription': false,
      'paid_access_elapsed_seconds': null,
    }, now: now, accountKey: 'two', previous: stored);
    expect(accessAvatarType(another, now), isNull);
    final revoked = ProfileAccessSnapshot.fromPayload({
      'hasActiveSubscription': false,
      'paid_access_elapsed_seconds': 0,
    }, now: now, accountKey: 'one', previous: stored);
    expect(accessAvatarType(revoked, now), GraniAvatarType.iskra);
  });
}

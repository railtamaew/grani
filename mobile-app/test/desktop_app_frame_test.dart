import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/widgets/desktop_app_frame.dart';

void main() {
  for (final window in [const Size(360, 610), const Size(420, 780),
    const Size(1280, 720), const Size(1920, 1080)]) {
    testWidgets('Windows preserves proportions at $window', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = window;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Size mediaSize;
      await tester.pumpWidget(MaterialApp(builder: (context, child) =>
        DesktopAppFrame(child: child!), home: Builder(builder: (context) {
          mediaSize = MediaQuery.sizeOf(context);
          return const Scaffold(body: SizedBox.expand(key: Key('content')));
        })));
      final rendered = tester.getSize(find.byKey(const Key('content')));
      expect(rendered, mediaSize);
      expect(rendered.width, lessThanOrEqualTo(412));
      expect(rendered.width / rendered.height, closeTo(412 / 917, 0.00001));
      expect(rendered.height, lessThanOrEqualTo(window.height));
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }
  testWidgets('Android keeps its full viewport and system text scale', (tester) async {
    const size = Size(430, 900);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Size mediaSize;
    await tester.pumpWidget(MaterialApp(builder: (context, child) =>
      DesktopAppFrame(child: child!), home: Builder(builder: (context) {
        mediaSize = MediaQuery.sizeOf(context);
        return const SizedBox.expand();
      })));
    expect(mediaSize, size);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

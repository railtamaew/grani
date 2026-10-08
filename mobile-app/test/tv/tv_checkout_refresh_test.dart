import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golden_toolkit/golden_toolkit.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_app/tv/tv_checkout_dialog.dart';
import 'tv_remote_test.dart' as qa;

void main() {
  setUpAll(loadAppFonts);
  testWidgets('expired QR disappears; remote refresh replaces it once',
      (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var now = DateTime.utc(2026, 10, 8);
    final replacement = Completer<Uri?>();
    var refreshes = 0;
    await tester.pumpWidget(qa.app(TvCheckoutDialog(
        uri: Uri.parse('https://granilink.com/ru/checkout#handoff=${'a' * 43}'),
        expiresAt: now.subtract(const Duration(seconds: 1)),
        now: () => now,
        onCheck: () {},
        onRefresh: () {
          refreshes++;
          return replacement.future;
        })));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsNothing);
    expect(find.text('QR-код истёк. Получите новый.'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(refreshes, 1);
    final newUri =
        Uri.parse('https://granilink.com/ru/checkout#handoff=${'b' * 43}');
    replacement.complete(newUri);
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey(newUri)), findsOneWidget);
    expect(tester.takeException(), isNull);
    await qa.screenshot(tester, 'wata-refreshed-qr');
    now = now.add(const Duration(minutes: 4));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed refresh keeps the QR expired and permits retry',
      (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime.utc(2026, 10, 8);
    await tester.pumpWidget(qa.app(TvCheckoutDialog(
        uri: Uri.parse('https://granilink.com/ru/checkout#handoff=${'a' * 43}'),
        expiresAt: now.subtract(const Duration(seconds: 1)),
        now: () => now,
        onCheck: () {},
        onRefresh: () async => null)));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsNothing);
    expect(find.textContaining('Не удалось обновить QR-код'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

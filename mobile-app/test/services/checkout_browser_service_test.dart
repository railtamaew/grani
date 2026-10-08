import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/services/checkout_browser_service.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/checkout-browser');
  late CheckoutBrowserService browser;
  final uri =
      Uri.parse('https://granilink.com/ru/checkout#handoff=${'A' * 43}');
  Future<void> closed() async {
    final delivered = Completer<void>();
    binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('closed')),
        (_) => delivered.complete());
    await delivered.future;
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    browser = CheckoutBrowserService.forTesting(channel);
  });
  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await browser.disposeForTesting();
  });
  test(
      'opening and duplicate closing report navigation without a payment verdict',
      () async {
    var events = 0;
    final sub = browser.closed.listen((_) {
      events++;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      expect(call.method, 'open');
      expect(call.arguments, {'url': uri.toString()});
      return true;
    });
    expect(await browser.open(uri), isTrue);
    expect(browser.isActive, isTrue);
    expect(events, 0);
    await closed();
    await closed();
    expect(events, 1);
    expect(browser.isActive, isFalse);
    await sub.cancel();
  });
  test('a second launch is blocked before overwriting a pending browser flow',
      () async {
    final started = Completer<bool>();
    var launches = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) {
      launches++;
      return started.future;
    });
    final first = browser.open(uri);
    await Future<void>.delayed(Duration.zero);
    expect(await browser.open(uri), isFalse);
    expect(launches, 1);
    started.complete(true);
    expect(await first, isTrue);
    await closed();
    expect(await browser.open(uri), isTrue);
    expect(launches, 2);
  });
  test(
      'launch failure allows retry and does not announce cancellation or success',
      () async {
    var attempts = 0;
    var events = 0;
    final sub = browser.closed.listen((_) {
      events++;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async {
      if (++attempts == 1) throw PlatformException(code: 'activity_missing');
      return true;
    });
    expect(await browser.open(uri), isFalse);
    expect(browser.isActive, isFalse);
    expect(events, 0);
    expect(await browser.open(uri), isTrue);
    expect(attempts, 2);
    await sub.cancel();
  });
}

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/services/install_attribution_service.dart';
import 'package:mobile_app/services/referral_service.dart';
import 'package:mobile_app/core/storage/shared_preferences_holder.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cold and warm invitation links preserve the code and target Friends',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    final prefs = await getSharedPreferences();
    await prefs.clear();
    const channel = MethodChannel('com.granivpn.mobile/app_links');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getInitialLink') {
        return 'https://granilink.com/open/invite?referral_code=ABCD2345EFGH';
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final service = InstallAttributionService.instance;
    await service.initialize();
    expect(await ReferralService.instance.pendingCode(), 'ABCD2345EFGH');
    expect(await service.takePendingRouteIfAuthorized(false), '/gift/receive');
    expect(await service.takePendingRouteIfAuthorized(true), '/gift/receive');
    await ReferralService.instance.finishGiftView();
    expect(await service.takePendingRouteIfAuthorized(true), isNull);

    await prefs.clear();
    final route = service.links.first;
    final reply = Completer<void>();
    messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(const MethodCall(
            'onAppLink', 'https://granilink.com/r/WARM2345ABCD')),
        (_) => reply.complete());
    await reply.future;
    expect(await route, '/gift/receive');
    expect(await ReferralService.instance.pendingCode(), 'WARM2345ABCD');
    final paymentRoute = service.links.first;
    final paymentReply = Completer<void>();
    messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(const MethodCall(
            'onAppLink', 'https://granilink.com/open/payment')),
        (_) => paymentReply.complete());
    await paymentReply.future;
    expect(await paymentRoute, '/payment-result');
    expect(await service.takePendingRouteIfAuthorized(false), isNull);
    expect(await service.takePendingRouteIfAuthorized(true), '/payment-result');
  });

  group('payment return navigation', () {
    const channel = MethodChannel('com.granivpn.mobile/app_links');
    const routeKey = 'grani_pending_app_link_route_v1';
    const intentKey = 'grani_website_checkout_intent_v1';
    const intentId = '8903e2ec-0ca6-42b5-ad2b-3d373c155001';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? initialLink;

    Future<void> deliver(String link) async {
      final reply = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall('onAppLink', link)),
        (_) => reply.complete(),
      );
      await reply.future;
    }

    setUp(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      initialLink = null;
      SharedPreferences.setMockInitialValues({});
      await (await getSharedPreferences()).clear();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getInitialLink') return initialLink;
        return null;
      });
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(channel, null);
    });

    test('legacy queued result cannot hijack launcher or erase purchase',
        () async {
      final prefs = await getSharedPreferences();
      await prefs.setString(routeKey, '/payment-result');
      await prefs.setString(intentKey, intentId);
      final service = InstallAttributionService.forTesting();
      await service.initialize();

      expect(await service.takePendingRouteIfAuthorized(true), isNull);
      expect(prefs.containsKey(routeKey), isFalse);
      expect(prefs.getString(intentKey), intentId);
    });

    test('fresh cold payment return waits for login and is consumed once',
        () async {
      initialLink = 'https://granilink.com/open/payment';
      final service = InstallAttributionService.forTesting();
      await service.initialize();

      expect(await service.takePendingRouteIfAuthorized(false), isNull);
      expect(
          await service.takePendingRouteIfAuthorized(true), '/payment-result');
      expect(await service.takePendingRouteIfAuthorized(true), isNull);
      expect((await getSharedPreferences()).containsKey(routeKey), isFalse);
    });

    test('handled warm return is absent from next ordinary launch', () async {
      final prefs = await getSharedPreferences();
      await prefs.setString(intentKey, intentId);
      final service = InstallAttributionService.forTesting();
      await service.initialize();
      final nextRoute = service.links.first;
      await deliver('https://granilink.com/open/payment');
      expect(await nextRoute, '/payment-result');
      await service.acknowledgeHandledRoute('/payment-result');
      expect(await service.takePendingRouteIfAuthorized(true), isNull);

      final relaunched = InstallAttributionService.forTesting();
      await relaunched.initialize();
      expect(await relaunched.takePendingRouteIfAuthorized(true), isNull);
      expect(prefs.getString(intentKey), intentId);
    });

    test('unhandled payment navigation does not survive process loss',
        () async {
      final prefs = await getSharedPreferences();
      await prefs.setString(intentKey, intentId);
      final service = InstallAttributionService.forTesting();
      await service.initialize();
      await deliver('https://granilink.com/open/payment');
      expect(await service.takePendingRouteIfAuthorized(false), isNull);

      final relaunched = InstallAttributionService.forTesting();
      await relaunched.initialize();
      expect(await relaunched.takePendingRouteIfAuthorized(true), isNull);
      expect(prefs.getString(intentKey), intentId);
    });

    test('older handled result cannot erase a newer invitation', () async {
      final service = InstallAttributionService.forTesting();
      await service.initialize();
      await deliver('https://granilink.com/open/payment');
      await deliver('https://granilink.com/r/NEXT2345ABCD');
      await service.acknowledgeHandledRoute('/payment-result');

      final relaunched = InstallAttributionService.forTesting();
      await relaunched.initialize();
      expect(
          await relaunched.takePendingRouteIfAuthorized(true), '/gift/receive');
      expect(await ReferralService.instance.pendingCode(), 'NEXT2345ABCD');
    });

    test('completed gift view keeps code but consumes navigation', () async {
      final service = InstallAttributionService.forTesting();
      await service.initialize();
      await deliver('https://granilink.com/r/GIFT2345ABCD');
      await service.acknowledgeHandledRoute('/gift/receive');
      await ReferralService.instance.finishGiftView();

      expect(await service.takePendingRouteIfAuthorized(true), isNull);
      expect(await ReferralService.instance.pendingCode(), 'GIFT2345ABCD');
    });

    test('payment after invitation preserves gift through process loss',
        () async {
      final prefs = await getSharedPreferences();
      await prefs.setString(intentKey, intentId);
      final service = InstallAttributionService.forTesting();
      await service.initialize();
      await deliver('https://granilink.com/r/GIFT2345ABCD');
      await deliver('https://granilink.com/open/payment');
      expect(await service.takePendingRouteIfAuthorized(false), isNull);
      expect(
          await service.takePendingRouteIfAuthorized(true), '/payment-result');
      await service.acknowledgeHandledRoute('/payment-result');

      final relaunched = InstallAttributionService.forTesting();
      await relaunched.initialize();
      expect(
          await relaunched.takePendingRouteIfAuthorized(true), '/gift/receive');
      expect(await ReferralService.instance.pendingCode(), 'GIFT2345ABCD');
      expect(prefs.getString(intentKey), intentId);
    });
  });

  test('lifecycle attribution stays compact for Firebase events', () {
    final parameters =
        InstallAttributionService.lifecycleAttributionParameters(const {
      'utm_source': 'google',
      'utm_medium': 'cpc',
      'utm_campaign': 'launch',
      'utm_content': 'video',
      'utm_term': 'vpn',
      'landing': '/ru',
      'locale': 'ru',
      'variant': 'control',
      'campaign': 'duplicate-name',
      'ad_group': 'group-1',
      'keyword_cluster': 'vpn',
      'attribution_id': '00000000-0000-0000-0000-000000000000',
      'click_time': '1775332800',
      'gclid': 'gclid-value',
      'gbraid': 'gbraid-value',
      'wbraid': 'wbraid-value',
    });

    expect(parameters, {
      'utm_source': 'google',
      'utm_medium': 'cpc',
      'utm_campaign': 'launch',
      'attribution_id': '00000000-0000-0000-0000-000000000000',
      'has_gclid': 1,
      'has_gbraid': 1,
      'has_wbraid': 1,
    });
    expect(parameters.length, lessThanOrEqualTo(7));
  });
}

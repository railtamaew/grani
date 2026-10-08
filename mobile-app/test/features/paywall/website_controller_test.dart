import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_app/features/paywall/controller/paywall_controller.dart';
import 'package:mobile_app/features/paywall/model/paywall_ui_state.dart';
import 'package:mobile_app/models/user.dart';
import 'package:mobile_app/services/subscription_service.dart';
import 'regional_paywall_controller_test.dart'
    show MockAuth, MockStore, MockAnalytics;
import 'regional_checkout_test.dart' show optionsJson;

void main() {
  test(
      'Windows initializes WATA without store and QR refresh never launches or credits',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    registerFallbackValue(<String, dynamic>{});
    final auth = MockAuth();
    final store = MockStore();
    final analytics = MockAnalytics();
    var account = User(
        id: '954',
        email: 'test@example.test',
        isEmailVerified: true,
        createdAt: DateTime(2026),
        isBlocked: false);
    when(() => auth.user).thenAnswer((_) => account);
    when(() => auth.refreshUserStatus(force: true)).thenAnswer((_) async {});
    when(() => store.purchaseEvents)
        .thenAnswer((_) => const Stream<BillingPurchaseEvent>.empty());
    when(() => store.hasPurchaseInFlight).thenReturn(false);
    when(() => analytics.logPaywallEvent(any(),
        parameters: any(named: 'parameters'))).thenAnswer((_) async {});
    var handoffs = 0;
    var opens = 0;
    var grants = 0;
    final requests = <String>[];
    when(() => auth.regionalBillingRequest(any(), any()))
        .thenAnswer((invocation) async {
      final path = invocation.positionalArguments[0] as String;
      requests.add(path);
      if (path.endsWith('/website/options')) {
        return {
          ...optionsJson(environment: 'production'),
          'routing_version': 1
        };
      }
      if (path.endsWith('/website/handoff')) {
        handoffs++;
        return {
          'intent_id':
              '00000000-0000-4000-8000-${handoffs.toString().padLeft(12, '0')}',
          'duration_days': 180,
          'amount_minor': 219000,
          'checkout_url':
              'https://granilink.com/ru/checkout#handoff=${(handoffs == 1 ? 'a' : 'b') * 43}'
        };
      }
      if (path.endsWith('/orders/latest')) return {'order': null};
      throw StateError('Unexpected request: $path');
    });
    final controller = PaywallController(
        subscriptionService: store,
        authService: auth,
        analyticsService: analytics,
        locale: 'ru',
        appLanguage: 'ru',
        trialState: 'expired',
        paywallSource: 'windows',
        defaultPlanId: '6_months',
        checkoutBrowserClosed: const Stream<void>.empty(),
        canOpenExternalCheckout: () async => true,
        isExternalCheckoutActive: () => false,
        openExternalCheckout: (_) async {
          opens++;
          return true;
        },
        onEntitlementGranted: () async {
          grants++;
        });
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.state.externalCheckout, isTrue);
    expect(controller.state.productsState, PaywallProductsState.ready);
    verifyNever(
        () => store.initialize(reconnectStore: any(named: 'reconnectStore')));
    await controller.purchaseSelected();
    expect(opens, 1);
    final renewed = await controller.refreshWebsiteCheckoutLink();
    expect(renewed?.fragment, 'handoff=${'b' * 43}');
    expect(handoffs, 2);
    expect(opens, 1);
    expect(grants, 0);
    expect(
        requests.any(
            (path) => path.contains('/origin/') || path.contains('/regional/')),
        isFalse);
    account = User(
        id: '955',
        email: 'other@example.test',
        isEmailVerified: true,
        createdAt: DateTime(2026),
        isBlocked: false);
    expect(await controller.refreshWebsiteCheckoutLink(), isNull);
    expect(handoffs, 2);
  });
}

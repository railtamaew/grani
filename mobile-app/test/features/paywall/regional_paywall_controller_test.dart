import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mobile_app/config/subscription_products.dart';
import 'package:mobile_app/features/paywall/controller/paywall_controller.dart';
import 'package:mobile_app/features/paywall/model/paywall_ui_state.dart';
import 'package:mobile_app/models/user.dart';
import 'package:mobile_app/services/analytics_service.dart';
import 'package:mobile_app/services/auth_service.dart';
import 'package:mobile_app/services/subscription_service.dart';
import 'package:mobile_app/services/regional_checkout_service.dart';
import 'regional_checkout_test.dart' show checkoutJson, optionsJson, orderId;

class MockAuth extends Mock implements AuthService {}

class MockStore extends Mock implements SubscriptionService {}

class MockAnalytics extends Mock implements AnalyticsService {}

class MockGoogleProduct extends Mock implements GooglePlayProductDetails {}

class MockProductWrapper extends Mock implements ProductDetailsWrapper {}

class MockOffer extends Mock implements OneTimePurchaseOfferDetailsWrapper {}

GooglePlayProductDetails googleProduct(String id) {
  final details = MockGoogleProduct();
  final wrapper = MockProductWrapper();
  final offer = MockOffer();
  when(() => details.id).thenReturn(id);
  when(() => details.price).thenReturn(r'$8.00');
  when(() => details.rawPrice).thenReturn(8);
  when(() => details.currencyCode).thenReturn('USD');
  when(() => details.currencySymbol).thenReturn(r'$');
  when(() => details.productDetails).thenReturn(wrapper);
  when(() => wrapper.oneTimePurchaseOfferDetails).thenReturn(offer);
  when(() => offer.priceAmountMicros).thenReturn(8000000);
  return details;
}

void main() {
  late MockAuth auth;
  late MockStore store;
  late MockAnalytics analytics;
  late User account;
  late String? country;
  late bool storeInitialized;
  late String environment;
  String? rememberedIntent;
  late int browserOpens;
  late Uri? openedUri;
  late int grants;
  late int orderCreates;
  late bool active;
  late String orderStatus;
  late List<String> keys;
  late PaywallController controller;
  late StreamController<void> browserClosed;
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>?)?
      overrideRequest;
  final user = User(
      id: '954',
      email: 'test@example.test',
      isEmailVerified: true,
      createdAt: DateTime(2026),
      isBlocked: false);

  setUp(() {
    auth = MockAuth();
    store = MockStore();
    analytics = MockAnalytics();
    account = user;
    rememberedIntent = null;
    country = 'RU';
    storeInitialized = false;
    environment = 'sandbox';
    browserOpens = 0;
    openedUri = null;
    grants = 0;
    orderCreates = 0;
    active = false;
    orderStatus = 'pending';
    keys = [];
    overrideRequest = null;
    when(() => auth.user).thenAnswer((_) => account);
    when(() => auth.hasActiveSubscription).thenAnswer((_) => active);
    when(() => auth.refreshUserStatus(force: true)).thenAnswer((_) async {});
    when(() => store.purchaseEvents)
        .thenAnswer((_) => const Stream<BillingPurchaseEvent>.empty());
    when(() => store.initialize(reconnectStore: any(named: 'reconnectStore')))
        .thenAnswer((_) async {
      storeInitialized = true;
    });
    when(() => store.hasPurchaseInFlight).thenReturn(false);
    when(() => store.isAvailable).thenReturn(true);
    when(() => store.lastRecoveryHadError).thenReturn(false);
    final products = [
      for (final id in [
        SubscriptionProducts.extension30Days,
        SubscriptionProducts.extension180Days,
        SubscriptionProducts.extension365Days
      ])
        googleProduct(id),
    ];
    when(() => store.products).thenReturn(products);
    when(() => store.recoverUnconsumedExtensions(
            applicationUserName: any(named: 'applicationUserName')))
        .thenAnswer((_) async => []);
    when(() => store.launchExtensionPurchase(any(),
            applicationUserName: any(named: 'applicationUserName')))
        .thenAnswer((_) async => true);
    when(() => analytics.logPaywallEvent(any(),
        parameters: any(named: 'parameters'))).thenAnswer((_) async {});
    when(() => analytics.logPaywallView(parameters: any(named: 'parameters')))
        .thenAnswer((_) async {});
    browserClosed = StreamController<void>.broadcast();
    controller = PaywallController(
      checkoutBrowserClosed: browserClosed.stream,
      subscriptionService: store,
      authService: auth,
      analyticsService: analytics,
      locale: 'ru',
      defaultPlanId: '1_month',
      paywallSource: 'test',
      trialState: 'expired',
      appLanguage: 'ru',
      onEntitlementGranted: () async {
        grants++;
      },
      openExternalCheckout: (uri) async {
        browserOpens++;
        openedUri = uri;
        return true;
      },
      regionalCheckoutService: RegionalCheckoutService(
          saveIntent: (id) async {
            rememberedIntent = id;
          },
          loadIntent: () async => rememberedIntent,
          loadReturnOrder: () async => null,
          saveReturnOrder: (_) async {},
          readCountry: () async => storeInitialized ? country : null,
          request: (path, body) async {
            if (overrideRequest != null) {
              return overrideRequest!(path, body);
            }
            if (path.endsWith('options')) {
              return optionsJson(environment: environment);
            }
            if (path.endsWith('/regional/orders')) {
              orderCreates++;
              keys.add(body!['idempotency_key'] as String);
            }
            return checkoutJson(status: orderStatus, environment: environment);
          }),
    );
  });
  tearDown(() async {
    controller.dispose();
    await browserClosed.close();
  });

  test('unknown Google country cannot launch either payment provider', () async {
    country = null;
    await controller.initialize();
    expect(controller.state.productsState, PaywallProductsState.error);
    expect(controller.state.errorKind, PaywallErrorKind.countryUnavailable);
    expect(controller.state.plans, isEmpty);
    expect(controller.state.selectedPlan, isNull);
    await controller.purchaseSelected();
    verifyNever(() => store.launchExtensionPurchase(any(),
        applicationUserName: any(named: 'applicationUserName')));
    expect(orderCreates, 0);
    expect(browserOpens, 0);
  });

  test('Kazakhstan country continues to show Google Play products', () async {
    country = 'KZ';
    await controller.initialize();
    expect(controller.state.externalCheckout, isFalse);
    expect(controller.state.productsState, PaywallProductsState.ready);
    expect(controller.state.plans, hasLength(3));
  });

  test('profile switch from KZ to RU before tap shows WATA without starting payment', () async {
    country = 'KZ';
    await controller.initialize();
    country = 'RU';
    await controller.purchaseSelected();
    expect(controller.state.externalCheckout, isTrue);
    expect(controller.state.productsState, PaywallProductsState.ready);
    verifyNever(() => store.launchExtensionPurchase(any(),
        applicationUserName: any(named: 'applicationUserName')));
    expect(browserOpens, 0);
    expect(orderCreates, 0);
  });

  test('country failure after tariffs loaded does not start a Google purchase', () async {
    country = 'KZ';
    await controller.initialize();
    country = null;
    await controller.purchaseSelected();
    expect(controller.state.errorKind, PaywallErrorKind.countryUnavailable);
    expect(controller.state.plans, isEmpty);
    verifyNever(() => store.launchExtensionPurchase(any(),
        applicationUserName: any(named: 'applicationUserName')));
  });

  test('Russian refusal clears old Google plans and shows a conflict', () async {
    country = 'KZ';
    await controller.initialize();
    country = 'RU';
    overrideRequest = (_, __) async =>
        {'provider': 'unavailable', 'reason': 'active_subscription'};
    await controller.retryProducts();
    expect(controller.state.productsState, PaywallProductsState.error);
    expect(controller.state.errorKind, PaywallErrorKind.paymentConflict);
    expect(controller.state.plans, isEmpty);
    await controller.purchaseSelected();
    verifyNever(() => store.launchExtensionPurchase(any(),
        applicationUserName: any(named: 'applicationUserName')));
  });

  test(
      'tab close and lifecycle resume share one check without inferring purchase from access',
      () async {
    environment = 'production';
    active = true;
    rememberedIntent = orderId;
    overrideRequest = (path, body) async {
      if (path.endsWith('options'))
        return optionsJson(environment: 'production');
      if (path.contains('/intents/'))
        return {
          'intent_id': orderId,
          'duration_days': 30,
          'state': 'ready',
          'order': null
        };
      return {'order': null};
    };
    await controller.initialize();
    final plan = controller.state.selectedPlanId;
    final gate = Completer<void>();
    var refreshes = 0;
    when(() => auth.refreshUserStatus(force: true)).thenAnswer((_) async {
      refreshes++;
      await gate.future;
    });
    final resumed = controller.onAppResumed();
    browserClosed.add(null);
    browserClosed.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(refreshes, 1);
    expect(controller.state.billingState, PaywallBillingState.verifying);
    expect(controller.state.isBusy, isTrue);
    expect(grants, 0);
    expect(orderCreates, 0);
    gate.complete();
    await resumed;
    await Future<void>.delayed(Duration.zero);
    expect(rememberedIntent, orderId);
    expect(controller.state.selectedPlanId, plan);
    expect(grants, 0);
    expect(controller.state.billingState, isNot(PaywallBillingState.success));
  });

  test('regional lookup waits for BillingClient setup instead of racing it',
      () async {
    final ready = Completer<void>();
    when(() => store.initialize(reconnectStore: any(named: 'reconnectStore')))
        .thenAnswer((_) async {
      await ready.future;
      storeInitialized = true;
    });
    final loading = controller.initialize();
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.productsState, PaywallProductsState.loading);
    ready.complete();
    await loading;
    expect(controller.state.externalCheckout, isTrue);
  });

  PaywallController managementController() => PaywallController(
      subscriptionService: store,
      authService: auth,
      analyticsService: analytics,
      locale: 'ru',
      defaultPlanId: '1_month',
      paywallSource: 'manage',
      trialState: 'paid_active',
      appLanguage: 'ru',
      onEntitlementGranted: () async {
        grants++;
      },
      openExternalCheckout: (uri) async {
        browserOpens++;
        return true;
      },
      regionalCheckoutService: RegionalCheckoutService(
        saveIntent: (id) async {
          rememberedIntent = id;
        },
        loadIntent: () async => rememberedIntent,
        loadReturnOrder: () async => null,
        saveReturnOrder: (_) async {},
        readCountry: () async => country,
        request: (path, body) async {
          if (path.endsWith('options')) {
            return optionsJson(environment: 'production');
          }
          if (path.endsWith('/handoff'))
            return {
              'intent_id': orderId,
              'duration_days': body!['duration_days'],
              'amount_minor': body['expected_amount_minor'],
              'checkout_url':
                  'https://granilink.com/ru/checkout#handoff=${'A' * 43}',
            };
          if (path.contains('/intents/'))
            return {'intent_id': orderId, 'order': null, 'state': 'ready'};
          final old = checkoutJson(status: 'paid', environment: 'production');
          if (path.endsWith('/latest')) return {'order': old};
          return old;
        },
      ));

  test(
      'existing access and unrelated expiration increase never confirm a new order',
      () async {
    controller.dispose();
    active = true;
    var expires = DateTime.utc(2026, 11, 1);
    when(() => auth.subscriptionExpiresAt).thenAnswer((_) => expires);
    controller = managementController();
    await controller.initialize();
    expect(grants, 0);
    expect(controller.state.billingState, PaywallBillingState.ready);
    await controller.purchaseSelected();
    expect(browserOpens, 1);
    await controller.onAppResumed();
    expect(grants, 0);
    expires = expires.add(const Duration(days: 30));
    await controller.onAppResumed();
    await controller.onAppResumed();
    expect(grants, 0);
  });

  test('unknown existing expiration never confirms a new website extension',
      () async {
    controller.dispose();
    active = true;
    controller = managementController();
    await controller.initialize();
    await controller.recoverPurchases(userInitiated: true);
    expect(grants, 0);
    expect(controller.state.billingState, PaywallBillingState.ready);
  });

  test('Russian language with US Play country retains Google purchases',
      () async {
    country = 'US';
    await controller.initialize();
    expect(controller.state.externalCheckout, isFalse);
    await controller.purchaseSelected();
    verify(() => store.launchExtensionPurchase(
        SubscriptionProducts.extension30Days,
        applicationUserName: any(named: 'applicationUserName'))).called(1);
    expect(browserOpens, 0);
    expect(orderCreates, 0);
  });

  test('browser return and pending order never grant access', () async {
    await controller.initialize();
    await controller.purchaseSelected();
    expect(browserOpens, 1);
    expect(controller.state.externalPending, isTrue);
    await controller.onAppResumed();
    expect(grants, 0);
    verifyNever(() => auth.refreshUserStatus(force: true));
    verifyNever(() => store.launchExtensionPurchase(any(),
        applicationUserName: any(named: 'applicationUserName')));
  });

  test('paid requires server entitlement and grants only once', () async {
    await controller.initialize();
    await controller.purchaseSelected();
    orderStatus = 'paid';
    await controller.recoverPurchases(userInitiated: true);
    expect(grants, 0);
    expect(controller.state.billingState, PaywallBillingState.error);
    active = true;
    await controller.recoverPurchases(userInitiated: true);
    await controller.recoverPurchases(userInitiated: true);
    expect(grants, 1);
    expect(controller.state.billingState, PaywallBillingState.success);
  });

  test('repeated taps reuse one idempotency key', () async {
    await controller.initialize();
    await controller.purchaseSelected();
    await controller.purchaseSelected();
    expect(keys.length, 2);
    expect(keys.toSet().length, 1);
  });

  test('late checkout response after account switch cannot open or grant',
      () async {
    await controller.initialize();
    final response = Completer<Map<String, dynamic>>();
    overrideRequest = (_, __) => response.future;
    final pending = controller.purchaseSelected();
    await Future<void>.delayed(Duration.zero);
    account = user.copyWith(id: '955');
    response.complete(checkoutJson());
    await pending;
    expect(browserOpens, 0);
    expect(grants, 0);
    expect(controller.state.isBusy, isFalse);
    expect(controller.state.productsState, PaywallProductsState.error);
  });

  test('changed country at CTA cannot open WATA or auto-launch Google',
      () async {
    await controller.initialize();
    country = 'US';
    await controller.purchaseSelected();
    expect(controller.state.externalCheckout, isFalse);
    expect(browserOpens, 0);
    expect(orderCreates, 0);
    verifyNever(() => store.launchExtensionPurchase(any(),
        applicationUserName: any(named: 'applicationUserName')));
  });

  test(
      'production opens approved site, creates no in-app order, and waits for entitlement',
      () async {
    environment = 'production';
    var completed = false;
    final paths = <String>[];
    overrideRequest = (path, body) async {
      paths.add(path);
      if (path.endsWith('options')) {
        return optionsJson(environment: 'production');
      }
      if (path.endsWith('/latest')) return {'order': null};
      if (path.endsWith('/handoff'))
        return {
          'intent_id': orderId,
          'duration_days': body!['duration_days'],
          'amount_minor': body['expected_amount_minor'],
          'checkout_url':
              'https://granilink.com/ru/checkout#handoff=${'A' * 43}',
        };
      if (path.contains('/intents/'))
        return {
          'intent_id': orderId,
          'state': completed ? 'completed' : 'ready',
          'order': completed
              ? checkoutJson(status: 'paid', environment: 'production')
              : null
        };
      throw StateError('Unexpected payment API request: $path');
    };
    await controller.initialize();
    expect(controller.state.externalCheckout, isTrue);
    expect(controller.state.externalSandbox, isFalse);
    controller.selectPlan('6_months');
    await controller.purchaseSelected();
    expect(browserOpens, 1);
    expect(openedUri?.host, 'granilink.com');
    expect(openedUri?.fragment, 'handoff=${'A' * 43}');
    expect(orderCreates, 0);
    await controller.recoverPurchases(userInitiated: true);
    expect(
        paths.every((path) =>
            path.endsWith('regional/options') ||
            path.endsWith('/latest') ||
            path.endsWith('/handoff') ||
            path.contains('/intents/')),
        isTrue);
    expect(grants, 0);
    active = true;
    await controller.onAppResumed();
    expect(grants, 0);
    completed = true;
    await controller.onAppResumed();
    await controller.onAppResumed();
    expect(grants, 1);
    expect(rememberedIntent,
        orderId); // Result screen, not the paywall, acknowledges it.
    await controller.retryProducts();
    expect(grants, 1); // The next purchase screen must not replay old success.
  });

  test('unfinished website selection restores after controller recreation',
      () async {
    environment = 'production';
    rememberedIntent = orderId;
    overrideRequest = (path, body) async {
      if (path.endsWith('options'))
        return optionsJson(environment: 'production');
      if (path.contains('/intents/'))
        return {
          'intent_id': orderId,
          'duration_days': 180,
          'state': 'ready',
          'order': null
        };
      throw StateError('Unexpected request');
    };
    await controller.initialize();
    expect(controller.state.selectedPlan?.periodDays, 180);
    controller.selectPlan('12_months');
    await controller.retryProducts();
    expect(controller.state.selectedPlan?.periodDays, 365);
  });
  test(
      'return with unpaid exact website order opens result without granting access',
      () async {
    var returns = 0;
    final check = PaywallController(
      subscriptionService: store,
      authService: auth,
      analyticsService: analytics,
      locale: 'ru',
      defaultPlanId: '1_month',
      paywallSource: 'test',
      trialState: 'paid_active',
      appLanguage: 'ru',
      onEntitlementGranted: () async {
        throw StateError('Pending is not paid');
      },
      onWebsitePurchaseReturn: () async {
        returns++;
      },
      regionalCheckoutService: RegionalCheckoutService(
        readCountry: () async => 'RU',
        loadIntent: () async => orderId,
        request: (path, body) async {
          if (path.endsWith('options'))
            return optionsJson(environment: 'production');
          return {
            'intent_id': orderId,
            'duration_days': 30,
            'state': 'awaiting_payment',
            'order': checkoutJson(environment: 'production')
          };
        },
      ),
    );
    addTearDown(check.dispose);
    await check.initialize();
    expect(returns, 0);
    await check.onAppResumed();
    expect(returns, 1);
    expect(check.state.billingState, isNot(PaywallBillingState.success));
    expect(orderCreates, 0);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/features/paywall/model/regional_checkout.dart';
import 'package:mobile_app/services/regional_checkout_service.dart';

const orderId = '00000000-0000-4000-8000-000000000001';
Map<String, dynamic> checkoutJson(
        {String status = 'pending', String environment = 'sandbox'}) =>
    {
      'order_id': orderId,
      'sandbox': environment == 'sandbox',
      if (environment == 'production') 'environment': 'production',
      'duration_days': 30,
      'amount_minor': 39900,
      'currency': 'RUB',
      'status': status,
      'expires_at': DateTime.now()
          .toUtc()
          .add(const Duration(hours: 1))
          .toIso8601String(),
      'checkout_url': status == 'pending'
          ? 'https://${environment == 'sandbox' ? 'payment-sandbox.wata.pro' : 'payment.wata.pro'}/pay-form/$orderId'
          : null,
    };
Map<String, dynamic> optionsJson({String environment = 'sandbox'}) => {
      'provider': 'wata',
      'environment': environment,
      'pending_order': null,
      'plans': [
        for (final e in {30: 39900, 180: 219000, 365: 389000}.entries)
          {'duration_days': e.key, 'amount_minor': e.value, 'currency': 'RUB'}
      ],
    };

void main() {
  test('missing Play input after resume is retried once without caching it',
      () async {
    var reads = 0;
    final service = RegionalCheckoutService(
      readCountry: () async => ++reads == 1 ? null : 'RU',
      request: (_, body) async {
        expect(body!['play_country'], 'RU');
        return optionsJson();
      },
    );
    expect((await service.resolve()).usesWata, isTrue);
    expect(reads, 2);
  });
  test('missing input retry honors a non-RU country and stays bounded',
      () async {
    for (final result in ['GB', null]) {
      var reads = 0;
      final service = RegionalCheckoutService(
        readCountry: () async => ++reads == 1 ? null : result,
        request: (_, __) async => throw StateError('must not contact WATA'),
      );
      expect((await service.resolve()).usesWata, isFalse);
      expect(reads, 2);
    }
  });
  test('expired bank attempt stays blocked unless server confirms it is final',
      () {
    for (final flag in [null, true, false]) {
      final order = RegionalOrder.fromJson({
        ...checkoutJson(status: 'expired', environment: 'production'),
        if (flag != null) 'blocks_new_order': flag,
      });
      expect(order.needsReview, flag != false);
      expect(order.canOpen, isFalse);
    }
    expect(
        () => RegionalOrder.fromJson({
              ...checkoutJson(status: 'expired', environment: 'production'),
              'blocks_new_order': 'false',
            }),
        throwsFormatException);
  });
  test('production checkout starts on the approved GRANI website', () {
    for (final days in [30, 180, 365]) {
      final uri = RegionalCheckoutService.websiteCheckoutUri(days);
      expect(uri.scheme, 'https');
      expect(uri.host, 'granilink.com');
      expect(uri.path, '/ru/checkout');
      expect(uri.queryParameters, {'plan': '$days'});
    }
    expect(() => RegionalCheckoutService.websiteCheckoutUri(1),
        throwsArgumentError);
  });

  for (final country in ['US', 'GB', 'BY', null, '', 'ru']) {
    test('$country never offers external checkout or creates an order',
        () async {
      var requests = 0;
      final service = RegionalCheckoutService(
          readCountry: () async => country,
          request: (_, __) async {
            requests++;
            return optionsJson();
          });
      expect((await service.resolve()).usesWata, isFalse);
      await expectLater(
          service.create(days: 30, amountMinor: 39900, idempotencyKey: orderId),
          throwsA(isA<RegionalCheckoutUnavailable>()));
      expect(requests, 0);
    });
  }

  test(
      'a fresh country is checked on every operation and after country changes',
      () async {
    var country = 'RU';
    var reads = 0;
    var requests = 0;
    final service = RegionalCheckoutService(readCountry: () async {
      reads++;
      return country;
    }, request: (path, body) async {
      requests++;
      expect(body!['play_country'], 'RU');
      return path.endsWith('options') ? optionsJson() : checkoutJson();
    });
    expect((await service.resolve()).usesWata, isTrue);
    expect(
        (await service.create(
                days: 30, amountMinor: 39900, idempotencyKey: orderId))
            .canOpen,
        isTrue);
    country = 'US';
    await expectLater(
        service.create(days: 30, amountMinor: 39900, idempotencyKey: orderId),
        throwsA(isA<RegionalCheckoutUnavailable>()));
    expect((await service.resolve()).usesWata, isFalse);
    expect(reads, 4);
    expect(requests, 2);
  });

  test('country, network and malformed options errors fail closed', () async {
    for (final failure in ['country', 'network', 'plans', 'unknown']) {
      final service = RegionalCheckoutService(readCountry: () async {
        if (failure == 'country') throw StateError('offline');
        return 'RU';
      }, request: (_, __) async {
        if (failure == 'network') throw StateError('offline');
        return {
          ...optionsJson(),
          if (failure == 'plans') 'plans': [],
          if (failure == 'unknown') 'environment': 'unknown'
        };
      });
      expect((await service.resolve()).usesWata, isFalse);
    }
  });

  test('refuses mismatched prices and external checkout URLs', () async {
    for (final change in <Map<String, dynamic>>[
      {'amount_minor': 1},
      {'duration_days': 365},
      {'sandbox': false},
      {'checkout_url': 'https://example.test/pay-form/$orderId'},
      {
        'checkout_url':
            'https://payment-sandbox.wata.pro.evil.test/pay-form/$orderId'
      },
      {
        'checkout_url':
            'https://user@payment-sandbox.wata.pro/pay-form/$orderId'
      },
      {
        'checkout_url':
            'https://payment-sandbox.wata.pro/pay-form/$orderId?redirect=evil'
      },
      {'checkout_url': 'http://payment-sandbox.wata.pro/pay-form/$orderId'},
    ]) {
      final service = RegionalCheckoutService(
          readCountry: () async => 'RU',
          request: (_, __) async => {...checkoutJson(), ...change});
      await expectLater(
          service.create(days: 30, amountMinor: 39900, idempotencyKey: orderId),
          throwsException);
    }
  });

  test('an ambiguous create is reconciled without another checkout POST',
      () async {
    final paths = <String>[];
    final service = RegionalCheckoutService(
        readCountry: () async => throw StateError('unused'),
        request: (path, body) async {
          paths.add(path);
          return checkoutJson(
              status: body == null ? 'create_unknown' : 'pending');
        });
    expect((await service.status(orderId)).canOpen, isTrue);
    expect(paths, [
      '/payments/wata/orders/$orderId',
      '/payments/wata/orders/$orderId/reconcile'
    ]);
  });

  test(
      'RUB presentation does not change the amount or billing route with locale',
      () {
    for (final locale in ['ru', 'en']) {
      final plan = const RegionalPlan(30, 39900).toTariff(locale);
      expect(plan.currencyCode, 'RUB');
      expect(plan.priceMicros, 399000000);
      expect(plan.productDetails, isNull);
    }
  });

  test('production options require a production order and matching host',
      () async {
    final service = RegionalCheckoutService(
        readCountry: () async => 'RU',
        request: (path, body) async {
          if (path.endsWith('options')) {
            return optionsJson(environment: 'production');
          }
          expect(body!['expected_environment'], 'production');
          return checkoutJson(environment: 'production');
        });
    final options = await service.resolve();
    expect(options.usesWata, isTrue);
    expect(options.environment, 'production');
    final order = await service.create(
        days: 30,
        amountMinor: 39900,
        idempotencyKey: orderId,
        expectedEnvironment: 'production');
    expect(order.environment, 'production');
    expect(order.canOpen, isTrue);
  });

  test('sandbox response cannot replace expected production payment', () async {
    final service = RegionalCheckoutService(
        readCountry: () async => 'RU',
        request: (_, __) async => checkoutJson());
    await expectLater(
        service.create(
            days: 30,
            amountMinor: 39900,
            idempotencyKey: orderId,
            expectedEnvironment: 'production'),
        throwsA(isA<RegionalCheckoutUnavailable>()));
  });

  test('production status uses the live endpoint', () async {
    final paths = <String>[];
    final service = RegionalCheckoutService(
        readCountry: () async => 'RU',
        request: (path, __) async {
          paths.add(path);
          return checkoutJson(environment: 'production');
        });
    expect(
        (await service.status(orderId, expectedEnvironment: 'production'))
            .canOpen,
        isTrue);
    expect(paths, [
      '/payments/wata/live/orders/$orderId',
      '/payments/wata/live/orders/$orderId/reconcile'
    ]);
  });
}

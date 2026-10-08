import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/services/regional_checkout_service.dart';
import 'regional_checkout_test.dart' show optionsJson, orderId;

void main() {
  test('Windows loads live RUB plans without any Google country or store',
      () async {
    final service =
        RegionalCheckoutService.website(request: (path, body) async {
      expect(path, '/payments/wata/website/options');
      expect(body, isEmpty);
      return {...optionsJson(environment: 'production'), 'routing_version': 1};
    });
    final options = await service.resolve();
    expect(service.requiresStoreCountry, isFalse);
    expect(options.usesWata, isTrue);
    expect(options.plans.map((p) => p.amountMinor), [39900, 219000, 389000]);
  });

  for (final response in <Map<String, dynamic>>[
    {},
    {'routing_version': 1, 'provider': 'google_play'},
    {...optionsJson(), 'routing_version': 1},
    {...optionsJson(environment: 'production'), 'routing_version': 2},
  ]) {
    test('Windows rejects incompatible payment options: $response', () async {
      final service =
          RegionalCheckoutService.website(request: (_, __) async => response);
      expect((await service.resolve()).unavailable, isTrue);
    });
  }

  test(
      'Windows handoff refresh never creates a provider order or stores its code',
      () async {
    final paths = <String>[];
    final persisted = <String>[];
    final service = RegionalCheckoutService.website(
        saveIntent: (value) async {
          persisted.add(value);
        },
        saveReturnOrder: (_) async {},
        request: (path, body) async {
          paths.add(path);
          expect(body, {'duration_days': 180, 'expected_amount_minor': 219000});
          return {
            'intent_id': orderId,
            'duration_days': 180,
            'amount_minor': 219000,
            'checkout_url':
                'https://granilink.com/ru/checkout#handoff=${'a' * 43}'
          };
        });
    for (var i = 0; i < 2; i++) {
      expect(
          (await service.prepareWebsiteCheckout(days: 180, amountMinor: 219000))
              .host,
          'granilink.com');
    }
    expect(paths, List.filled(2, '/payments/wata/website/handoff'));
    expect(persisted, List.filled(2, orderId));
    expect(service.handoffExpiresAt, isNotNull);
    await expectLater(
        service.create(
            days: 180,
            amountMinor: 219000,
            idempotencyKey: orderId,
            expectedEnvironment: 'production'),
        throwsA(isA<RegionalCheckoutUnavailable>()));
    expect(paths.length, 2);
  });
}

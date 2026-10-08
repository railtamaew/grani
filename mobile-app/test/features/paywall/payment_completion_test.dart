import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/services/regional_checkout_service.dart';
import 'regional_checkout_test.dart' show orderId, checkoutJson;

void main() {
  test('separate browser return resolves exact owned order without Play lookup',
      () async {
    var reads = 0;
    final paths = <String>[];
    final service = RegionalCheckoutService(
      readCountry: () async {
        reads++;
        return 'GB';
      },
      loadIntent: () async => '11111111-1111-4111-8111-111111111111',
      loadReturnOrder: () async => orderId,
      request: (path, body) async {
        paths.add(path);
        expect(body, isNull);
        return {
          'intent_id': orderId,
          'order': checkoutJson(environment: 'production')
        };
      },
    );
    expect((await service.websitePaymentResultContext())!['order']['order_id'],
        orderId);
    expect(paths, ['/payments/wata/live/checkout/orders/$orderId/context']);
    expect(reads, 0);
  });
  test('old completed return cannot discard a newer financial intent',
      () async {
    var intent = '11111111-1111-4111-8111-111111111111';
    var returned = orderId;
    final service = RegionalCheckoutService(
      readCountry: () async => null,
      request: (_, __) async => throw StateError('no network needed'),
      loadIntent: () async => intent,
      saveIntent: (id) async {
        intent = id;
      },
      loadReturnOrder: () async => returned,
      saveReturnOrder: (id) async {
        returned = id;
      },
    );
    await service.acknowledgePaymentResult({
      'intent_id': orderId,
      'order': checkoutJson(environment: 'production')
    });
    expect(returned, '');
    expect(intent, '11111111-1111-4111-8111-111111111111');
  });
  test('mismatched order result is rejected rather than shown as successful',
      () async {
    final service = RegionalCheckoutService(
      readCountry: () async => null,
      loadReturnOrder: () async => orderId,
      request: (_, __) async => {
        'order': {
          'order_id': '11111111-1111-4111-8111-111111111111',
          'status': 'paid'
        }
      },
    );
    await expectLater(service.websitePaymentResultContext(),
        throwsA(isA<RegionalCheckoutUnavailable>()));
  });
}

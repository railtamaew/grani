import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/services/regional_checkout_service.dart';

void main() {
  test('new routing asks server without a Google country', () async {
    final service = RegionalCheckoutService.origin(request: (path, body) async {
      expect(path, '/payments/wata/origin/options');
      expect(body, isEmpty);
      return {'routing_version': 2, 'provider': 'google_play'};
    });
    final result = await service.resolve();
    expect(result.usesWata, isFalse);
    expect(result.unavailable, isFalse);
  });
  test('Russia uses server WATA tariffs without reading Play', () async {
    final service = RegionalCheckoutService.origin(request: (path, body) async => {
      'routing_version': 2, 'provider': 'wata', 'environment': 'production',
      'plans': [for(final days in [30,180,365]) {'duration_days':days, 'amount_minor':39900, 'currency':'RUB'}],
    });
    expect((await service.resolve()).usesWata, isTrue);
  });
  for (final response in <Map<String,dynamic>>[
    {}, {'provider':'google_play'}, {'routing_version':2},
    {'routing_version':2,'provider':'unexpected'},
    {'routing_version':2,'provider':'unavailable','reason':'region_unavailable'},
  ]) {
    test('unknown response fails closed: $response', () async {
      final service=RegionalCheckoutService.origin(request: (_,__) async=>response);
      expect((await service.resolve()).unavailable,isTrue);
    });
  }
  test('network failure never selects Google', () async {
    final service=RegionalCheckoutService.origin(request: (_,__) async=>throw Exception('offline'));
    expect((await service.resolve()).unavailable,isTrue);
  });
  test('handoff uses direct origin endpoint and no client country', () async {
    final service=RegionalCheckoutService.origin(saveIntent: (_) async {},saveReturnOrder: (_)async{},request:(path,body)async{
      expect(path,'/payments/wata/live/checkout/origin/handoff');
      expect(body,{'duration_days':30,'expected_amount_minor':39900});
      return {'intent_id':'b3eb1c2d-dc33-4a79-bf5f-cfe62d651ed5','duration_days':30,'amount_minor':39900,
        'checkout_url':'https://granilink.com/ru/checkout#handoff=${'a'*43}'};
    });
    expect((await service.prepareWebsiteCheckout(days:30,amountMinor:39900)).host,'granilink.com');
  });
}

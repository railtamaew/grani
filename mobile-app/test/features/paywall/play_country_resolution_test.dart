import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/services/regional_checkout_service.dart';
import 'regional_checkout_test.dart' show optionsJson;

void main() {
  for (final country in ['KZ', 'SG', 'GB']) {
    test('$country uses Google despite available Russian provider', () async {
      final service = RegionalCheckoutService(readCountry: () async => country,
        request: (_, __) => throw StateError('must not request Russian payment'));
      final result = await service.resolve();
      expect(result.usesWata, isFalse);
      expect(result.unavailable, isFalse);
    });
  }
  test('RU requests Russian provider from authenticated backend', () async {
    final service = RegionalCheckoutService(readCountry: () async => 'RU',
      request: (path, body) async {
        expect(path, '/payments/wata/regional/options');
        expect(body, {'play_country': 'RU'});
        return optionsJson(environment: 'production');
      });
    expect((await service.resolve()).usesWata, isTrue);
  });
  test('missing profile/config is retried and not labelled as Google country', () async {
    var reads = 0;
    final service = RegionalCheckoutService(readCountry: () async { reads++; return null; },
      request: (_, __) => throw StateError('unknown country cannot select WATA'));
    final result = await service.resolve();
    expect(reads, 2);
    expect(result.unavailableReason, 'country_required');
  });
  test('Billing failure is a retry state, not a foreign-country result', () async {
    final service = RegionalCheckoutService(readCountry: () => throw StateError('Billing error'),
      request: (_, __) => throw StateError('must not request WATA'));
    expect((await service.resolve()).unavailableReason, 'country_required');
  });
  test('Russian server refusal does not silently switch to Google', () async {
    for (final json in [ {'provider': 'google_play'},
      {'provider': 'unavailable', 'reason': 'active_subscription'} ]) {
      final service = RegionalCheckoutService(readCountry: () async => 'RU',
          request: (_, __) async => json);
      expect((await service.resolve()).unavailable, isTrue);
    }
  });
  test('Russian endpoint outage preserves a retry state for Russian payment', () async {
    final service = RegionalCheckoutService(readCountry: () async => 'RU',
      request: (_, __) => throw StateError('offline'));
    expect((await service.resolve()).unavailableReason, 'temporarily_unavailable');
  });
  test('country is read again after switching the Google Play country profile', () async {
    var country = 'KZ';
    final service = RegionalCheckoutService(readCountry: () async => country,
      request: (_, __) async => optionsJson(environment: 'production'));
    expect((await service.resolve()).usesWata, isFalse);
    country = 'RU';
    expect((await service.resolve()).usesWata, isTrue);
    country = 'KZ';
    expect((await service.resolve()).usesWata, isFalse);
  });
}

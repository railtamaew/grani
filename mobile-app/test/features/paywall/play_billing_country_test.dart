import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:mobile_app/services/play_billing_country.dart';

void main() {
  for (final country in ['RU', 'KZ', 'SG', 'GB']) {
    test('accepts the country returned by a successful Google operation: $country', () {
      expect(verifiedPlayBillingCountry(BillingResponse.ok, country), country);
    });
  }
  for (final status in [BillingResponse.error, BillingResponse.serviceDisconnected,
    BillingResponse.billingUnavailable]) {
    test('an error with a country-looking value remains unknown: $status', () {
      expect(verifiedPlayBillingCountry(status, 'RU'), isNull);
    });
  }
  for (final value in ['', 'ru', 'RUS', 'R', ' RU']) {
    test('invalid or absent country stays unknown: $value', () {
      expect(verifiedPlayBillingCountry(BillingResponse.ok, value), isNull);
    });
  }
}

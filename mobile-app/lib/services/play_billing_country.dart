import 'package:in_app_purchase_android/billing_client_wrappers.dart';

/// Accept only an error-free, valid country from this one Billing operation.
/// Neither country nor debug message is cached, logged or persisted.
String? verifiedPlayBillingCountry(BillingResponse response, String country) {
  if (response != BillingResponse.ok) return null;
  return RegExp(r'^[A-Z]{2}$').hasMatch(country) ? country : null;
}

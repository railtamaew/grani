import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/config/subscription_products.dart';

void main() {
  test('repeatable extension products are separate from subscriptions', () {
    expect(SubscriptionProducts.subscriptions, hasLength(3));
    expect(SubscriptionProducts.extensions, hasLength(3));
    expect(SubscriptionProducts.all, hasLength(6));

    expect(
      SubscriptionProducts.isSubscription(SubscriptionProducts.monthly),
      isTrue,
    );
    expect(
      SubscriptionProducts.isExtension(
        SubscriptionProducts.extension30Days,
      ),
      isTrue,
    );
    expect(
      SubscriptionProducts.isExtension(SubscriptionProducts.monthly),
      isFalse,
    );
  });
}

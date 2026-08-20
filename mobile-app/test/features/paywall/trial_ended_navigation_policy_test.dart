import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/screens/trial_ended_screen.dart';

void main() {
  test('expired paywall cannot be dismissed', () {
    expect(
      canDismissSubscriptionScreen(SubscriptionScreenMode.expired),
      isFalse,
    );
  });

  test('voluntary subscription screens remain dismissible', () {
    expect(
      canDismissSubscriptionScreen(SubscriptionScreenMode.upgrade),
      isTrue,
    );
    expect(
      canDismissSubscriptionScreen(SubscriptionScreenMode.manage),
      isTrue,
    );
  });
}

/// Идентификаторы подписок в Google Play Console.
/// Соответствуют продуктам: GRANI (1 мес.), GRANI 6 months - 15%, GRANI 1 year - 30%.
class SubscriptionProducts {
  SubscriptionProducts._();

  static const String monthly = 'com.granivpn.mobile.subscription.monthly';
  static const String sixMonths = 'com.granivpn.mobile.subscription.6months';
  static const String yearly = 'com.granivpn.mobile.subscription.yearly';

  /// Consumable paid-access extensions. Google Play consumes each purchase
  /// after backend verification, so the same period can be bought repeatedly
  /// and can be credited to the currently signed-in GRANI account.
  static const String extension30Days = 'com.granivpn.mobile.extension.30days';
  static const String extension180Days =
      'com.granivpn.mobile.extension.180days';
  static const String extension365Days =
      'com.granivpn.mobile.extension.365days';

  static const List<String> subscriptions = [monthly, sixMonths, yearly];
  static const List<String> extensions = [
    extension30Days,
    extension180Days,
    extension365Days,
  ];
  static const List<String> all = [...subscriptions, ...extensions];

  static bool isSubscription(String productId) =>
      subscriptions.contains(productId);

  static bool isExtension(String productId) => extensions.contains(productId);
}

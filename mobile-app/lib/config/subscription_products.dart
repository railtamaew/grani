/// Идентификаторы подписок в Google Play Console.
/// Соответствуют продуктам: GRANI (1 мес.), GRANI 6 months - 15%, GRANI 1 year - 30%.
class SubscriptionProducts {
  SubscriptionProducts._();

  static const String monthly = 'com.granivpn.mobile.subscription.monthly';
  static const String sixMonths = 'com.granivpn.mobile.subscription.6months';
  static const String yearly = 'com.granivpn.mobile.subscription.yearly';

  static const List<String> all = [monthly, sixMonths, yearly];
}

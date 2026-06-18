import 'app_localizations.dart';

/// Название тарифа с бэкенда ([subscription_plan_name]) хранится на языке БД;
/// для UI показываем строку в локали приложения.
String localizedSubscriptionPlanDisplay(AppLocalizations l10n, String? raw) {
  if (raw == null || raw.isEmpty) {
    return l10n.profileSubscriptionPlanNameFallback;
  }
  final t = raw.trim();
  final l = t.toLowerCase();

  if (t == '1 месяц' ||
      t == 'Месячная' ||
      l == '1 month' ||
      l == 'monthly') {
    return l10n.paymentTariffTitleOneMonth;
  }
  if (t == '6 месяцев' ||
      t == '6 месяца' ||
      t == 'Полугодовая' ||
      l == '6 months' ||
      l == 'semiannual') {
    return l10n.paymentTariffTitleSixMonths;
  }
  if (t == '1 год' ||
      t == '12 месяцев' ||
      t == 'Годовая' ||
      l == '1 year' ||
      l == 'annual' ||
      l == 'yearly') {
    return l10n.paymentTariffTitleOneYear;
  }
  if (l == 'premium') {
    return l10n.profileSubscriptionPlanNameFallback;
  }

  return t;
}

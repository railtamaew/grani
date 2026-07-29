import 'app_localizations.dart';

/// Название плана с бэкенда ([subscription_plan_name]) хранится как служебное
/// значение. В пользовательском UI показываем единый продуктовый доступ.
String localizedSubscriptionPlanDisplay(AppLocalizations l10n, String? raw) {
  return l10n.profileSubscriptionPlanNameFallback;
}

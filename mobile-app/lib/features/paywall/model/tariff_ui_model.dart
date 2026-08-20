import 'package:in_app_purchase/in_app_purchase.dart';

/// Immutable UI representation of a Google Play one-time access product.
class TariffUiModel {
  const TariffUiModel({
    required this.id,
    required this.productId,
    required this.periodMonths,
    required this.periodDays,
    required this.formattedMonthlyPrice,
    required this.formattedTotalPrice,
    required this.priceMicros,
    required this.monthlyEquivalentMicros,
    required this.currencyCode,
    required this.illustrationNeutral,
    required this.illustrationSelected,
    required this.productDetails,
    this.savingsPercent,
    this.isBestValue = false,
  });

  final String id;
  final String productId;
  final int periodMonths;
  final int periodDays;
  final String formattedMonthlyPrice;
  final String formattedTotalPrice;
  final int priceMicros;
  final int monthlyEquivalentMicros;
  final String currencyCode;
  final int? savingsPercent;
  final bool isBestValue;
  final String illustrationNeutral;
  final String illustrationSelected;
  final ProductDetails productDetails;
}

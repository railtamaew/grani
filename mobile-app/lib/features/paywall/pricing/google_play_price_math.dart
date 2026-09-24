import 'dart:math' as math;

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:intl/intl.dart';

/// Exact integer price calculations for Google Play products.
///
/// All arithmetic is performed in micros/minor units. A floating point value
/// is created only at the final NumberFormat boundary, never for calculation.
class GooglePlayPriceMath {
  const GooglePlayPriceMath._();

  static int? priceMicros(ProductDetails details) {
    if (details is! GooglePlayProductDetails) return null;
    return details
        .productDetails
        .oneTimePurchaseOfferDetails
        ?.priceAmountMicros;
  }

  static int fractionDigits(String currencyCode, String locale) {
    final digits = NumberFormat.currency(
      locale: locale,
      name: currencyCode,
    ).decimalDigits;
    return (digits ?? 2).clamp(0, 6).toInt();
  }

  static int monthlyAmountMinorUnits({
    required int priceMicros,
    required int periodMonths,
    required int fractionDigits,
  }) {
    if (priceMicros < 0 || periodMonths <= 0) {
      throw ArgumentError('Price and period must be positive');
    }
    final scale = _pow10(fractionDigits);
    final numerator = priceMicros * scale;
    final denominator = periodMonths * 1000000;
    return (numerator + denominator ~/ 2) ~/ denominator;
  }

  static int monthlyEquivalentMicros({
    required int priceMicros,
    required int periodMonths,
    required int fractionDigits,
  }) {
    final minor = monthlyAmountMinorUnits(
      priceMicros: priceMicros,
      periodMonths: periodMonths,
      fractionDigits: fractionDigits,
    );
    return minor * (1000000 ~/ _pow10(fractionDigits));
  }

  static int? savingsPercent({
    required int monthlyPlanPriceMicros,
    required int planPriceMicros,
    required int periodMonths,
  }) {
    if (monthlyPlanPriceMicros <= 0 ||
        planPriceMicros <= 0 ||
        periodMonths <= 1) {
      return null;
    }
    final baseline = monthlyPlanPriceMicros * periodMonths;
    final saved = baseline - planPriceMicros;
    if (saved <= 0) return null;
    final rounded = (saved * 100 + baseline ~/ 2) ~/ baseline;
    return rounded > 0 ? rounded : null;
  }

  static String formatMonthlyPrice({
    required ProductDetails details,
    required int priceMicros,
    required int periodMonths,
    required String locale,
  }) {
    final digits = fractionDigits(details.currencyCode, locale);
    final scale = _pow10(digits);
    final minor = monthlyAmountMinorUnits(
      priceMicros: priceMicros,
      periodMonths: periodMonths,
      fractionDigits: digits,
    );
    return _formatMinorUnits(
      minor: minor,
      scale: scale,
      details: details,
      locale: locale,
      fractionDigits: digits,
    );
  }

  static String formatTotalPrice({
    required ProductDetails details,
    required int priceMicros,
    required String locale,
  }) {
    final digits = fractionDigits(details.currencyCode, locale);
    final scale = _pow10(digits);
    final minor = monthlyAmountMinorUnits(
      priceMicros: priceMicros,
      periodMonths: 1,
      fractionDigits: digits,
    );
    return _formatMinorUnits(
      minor: minor,
      scale: scale,
      details: details,
      locale: locale,
      fractionDigits: digits,
    );
  }

  static String _formatMinorUnits({
    required int minor,
    required int scale,
    required ProductDetails details,
    required String locale,
    required int fractionDigits,
  }) {
    final valueForFormatting = minor / scale;
    final storeSymbol = details.currencySymbol.trim();
    final displaySymbol = storeSymbol.isEmpty
        ? details.currencyCode
        : storeSymbol;
    return NumberFormat.currency(
      locale: locale,
      name: details.currencyCode,
      // Some Play Billing responses contain an empty currencySymbol even
      // though currencyCode is present. Never render a price without a
      // visible currency marker.
      symbol: displaySymbol,
      decimalDigits: fractionDigits,
    ).format(valueForFormatting);
  }

  static int _pow10(int exponent) => math.pow(10, exponent).toInt();
}

import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:mobile_app/features/paywall/pricing/google_play_price_math.dart';

void main() {
  group('GooglePlayPriceMath', () {
    final rubDetails = ProductDetails(
      id: 'rub_product',
      title: 'RUB product',
      description: 'RUB product',
      price: '399,00 ₽',
      rawPrice: 399,
      currencyCode: 'RUB',
      currencySymbol: '₽',
    );

    test('rounds GBP 59.99 / 12 to GBP 5.00', () {
      expect(
        GooglePlayPriceMath.monthlyAmountMinorUnits(
          priceMicros: 59990000,
          periodMonths: 12,
          fractionDigits: 2,
        ),
        500,
      );
      expect(
        GooglePlayPriceMath.monthlyEquivalentMicros(
          priceMicros: 59990000,
          periodMonths: 12,
          fractionDigits: 2,
        ),
        5000000,
      );
    });

    test('calculates savings against the one-month product', () {
      expect(
        GooglePlayPriceMath.savingsPercent(
          monthlyPlanPriceMicros: 6990000,
          planPriceMicros: 36490000,
          periodMonths: 6,
        ),
        13,
      );
      expect(
        GooglePlayPriceMath.savingsPercent(
          monthlyPlanPriceMicros: 6990000,
          planPriceMicros: 59990000,
          periodMonths: 12,
        ),
        28,
      );
    });

    test('does not show savings for an invalid or non-beneficial plan', () {
      expect(
        GooglePlayPriceMath.savingsPercent(
          monthlyPlanPriceMicros: 0,
          planPriceMicros: 59990000,
          periodMonths: 12,
        ),
        isNull,
      );
      expect(
        GooglePlayPriceMath.savingsPercent(
          monthlyPlanPriceMicros: 4990000,
          planPriceMicros: 6990000,
          periodMonths: 1,
        ),
        isNull,
      );
    });

    test('formats monthly and total prices with the same app locale', () {
      final monthly = GooglePlayPriceMath.formatMonthlyPrice(
        details: rubDetails,
        priceMicros: 399000000,
        periodMonths: 1,
        locale: 'en',
      );
      final total = GooglePlayPriceMath.formatTotalPrice(
        details: rubDetails,
        priceMicros: 399000000,
        locale: 'en',
      );

      expect(total, monthly);
      expect(total, contains('399.00'));
      expect(total, contains('₽'));
    });

    test('falls back to ISO currency code when Play omits the symbol', () {
      final gbpWithoutSymbol = ProductDetails(
        id: 'gbp_product',
        title: 'GBP product',
        description: 'GBP product',
        price: '4.49',
        rawPrice: 4.49,
        currencyCode: 'GBP',
        currencySymbol: '',
      );

      final monthly = GooglePlayPriceMath.formatMonthlyPrice(
        details: gbpWithoutSymbol,
        priceMicros: 4490000,
        periodMonths: 1,
        locale: 'ru',
      );
      final total = GooglePlayPriceMath.formatTotalPrice(
        details: gbpWithoutSymbol,
        priceMicros: 4490000,
        locale: 'ru',
      );

      expect(monthly, total);
      expect(total, contains('4,49'));
      expect(total, contains('GBP'));
    });
  });
}

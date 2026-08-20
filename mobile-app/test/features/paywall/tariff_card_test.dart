import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:mobile_app/features/paywall/model/tariff_ui_model.dart';
import 'package:mobile_app/features/paywall/widgets/tariff_card.dart';

void main() {
  testWidgets('the full selected card is one accessible tap target',
      (tester) async {
    var taps = 0;
    final details = ProductDetails(
      id: 'product',
      title: 'Product',
      description: 'Description',
      price: r'$47.99',
      rawPrice: 47.99,
      currencyCode: 'USD',
      currencySymbol: r'$',
    );
    final plan = TariffUiModel(
      id: '12_months',
      productId: details.id,
      periodMonths: 12,
      periodDays: 365,
      formattedMonthlyPrice: r'$4.00',
      formattedTotalPrice: details.price,
      priceMicros: 47990000,
      monthlyEquivalentMicros: 4000000,
      currencyCode: 'USD',
      savingsPercent: 20,
      isBestValue: true,
      illustrationNeutral: 'assets/images/tariffs/plan_token_12_neutral.png',
      illustrationSelected: 'assets/images/tariffs/plan_token_12_selected.png',
      productDetails: details,
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TariffCard(
          plan: plan,
          selected: true,
          enabled: true,
          title: '12 months',
          perMonthLabel: '/ mo',
          totalLabel: 'Total',
          bestValueLabel: 'Best value',
          savingsLabel: 'Save 20%',
          semanticsLabel: '12 months. Selected.',
          reducedMotion: true,
          onSelected: () => taps++,
        ),
      ),
    ));

    await tester.tap(find.byType(TariffCard));
    await tester.pump();
    expect(taps, 1);

    final semantics = tester.getSemantics(find.bySemanticsLabel(
      '12 months. Selected.',
    ));
    expect(semantics.hasFlag(ui.SemanticsFlag.isSelected), isTrue);
    expect(semantics.hasFlag(ui.SemanticsFlag.isButton), isTrue);
  });
}

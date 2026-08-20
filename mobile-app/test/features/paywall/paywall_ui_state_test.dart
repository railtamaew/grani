import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:mobile_app/features/paywall/model/paywall_ui_state.dart';
import 'package:mobile_app/features/paywall/model/tariff_ui_model.dart';

void main() {
  final details = ProductDetails(
    id: 'product',
    title: 'Product',
    description: 'Description',
    price: r'$4.99',
    rawPrice: 4.99,
    currencyCode: 'USD',
    currencySymbol: r'$',
  );
  final plan = TariffUiModel(
    id: '12_months',
    productId: 'product',
    periodMonths: 12,
    periodDays: 365,
    formattedMonthlyPrice: r'$4.00',
    formattedTotalPrice: r'$47.99',
    priceMicros: 47990000,
    monthlyEquivalentMicros: 4000000,
    currencyCode: 'USD',
    savingsPercent: 20,
    isBestValue: true,
    illustrationNeutral: 'neutral.png',
    illustrationSelected: 'selected.png',
    productDetails: details,
  );

  test('keeps one selected plan while billing state changes', () {
    final ready = PaywallUiState(
      productsState: PaywallProductsState.ready,
      plans: [plan],
      selectedPlanId: plan.id,
    );
    expect(ready.selectedPlan, same(plan));
    expect(ready.isBusy, isFalse);

    final pending = ready.copyWith(
      billingState: PaywallBillingState.pending,
    );
    expect(pending.selectedPlanId, plan.id);
    expect(pending.isBusy, isTrue);

    final canceled = pending.copyWith(
      billingState: PaywallBillingState.ready,
      clearError: true,
    );
    expect(canceled.selectedPlanId, plan.id);
    expect(canceled.isBusy, isFalse);
  });

  test('all blocking billing states disable interaction', () {
    for (final billingState in const [
      PaywallBillingState.launching,
      PaywallBillingState.awaitingResult,
      PaywallBillingState.pending,
      PaywallBillingState.verifying,
      PaywallBillingState.restoring,
    ]) {
      expect(
        PaywallUiState(billingState: billingState).isBusy,
        isTrue,
        reason: billingState.name,
      );
    }
  });
}

import 'tariff_ui_model.dart';

enum PaywallProductsState { loading, ready, error }

enum PaywallBillingState {
  ready,
  launching,
  awaitingResult,
  pending,
  verifying,
  success,
  restoring,
  error,
}

enum PaywallErrorKind {
  productsUnavailable,
  launchFailed,
  storeUnavailable,
  verificationFailed,
  billingError,
  restoreFailed,
}

class PaywallUiState {
  const PaywallUiState({
    this.productsState = PaywallProductsState.loading,
    this.plans = const <TariffUiModel>[],
    this.selectedPlanId,
    this.billingState = PaywallBillingState.ready,
    this.errorKind,
    this.experimentVariant = 'control',
    this.timeToLoadProductsMs,
  });

  final PaywallProductsState productsState;
  final List<TariffUiModel> plans;
  final String? selectedPlanId;
  final PaywallBillingState billingState;
  final PaywallErrorKind? errorKind;
  final String experimentVariant;
  final int? timeToLoadProductsMs;

  TariffUiModel? get selectedPlan {
    for (final plan in plans) {
      if (plan.id == selectedPlanId) return plan;
    }
    return null;
  }

  bool get isBusy => switch (billingState) {
        PaywallBillingState.launching ||
        PaywallBillingState.awaitingResult ||
        PaywallBillingState.pending ||
        PaywallBillingState.verifying ||
        PaywallBillingState.restoring =>
          true,
        _ => false,
      };

  PaywallUiState copyWith({
    PaywallProductsState? productsState,
    List<TariffUiModel>? plans,
    String? selectedPlanId,
    PaywallBillingState? billingState,
    PaywallErrorKind? errorKind,
    bool clearError = false,
    String? experimentVariant,
    int? timeToLoadProductsMs,
  }) {
    return PaywallUiState(
      productsState: productsState ?? this.productsState,
      plans: plans ?? this.plans,
      selectedPlanId: selectedPlanId ?? this.selectedPlanId,
      billingState: billingState ?? this.billingState,
      errorKind: clearError ? null : (errorKind ?? this.errorKind),
      experimentVariant: experimentVariant ?? this.experimentVariant,
      timeToLoadProductsMs: timeToLoadProductsMs ?? this.timeToLoadProductsMs,
    );
  }
}

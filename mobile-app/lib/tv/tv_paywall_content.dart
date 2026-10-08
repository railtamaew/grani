import 'package:flutter/material.dart';
import '../features/paywall/model/paywall_ui_state.dart';
import '../features/paywall/widgets/paywall_header.dart';
import '../features/paywall/widgets/tariff_card.dart';
import '../features/paywall/widgets/premium_action_surface.dart';
import '../features/paywall/widgets/trust_items.dart';
import '../l10n/l10n.dart';
import 'tv_ui.dart';

/// The same tariff artwork, layout and checkout surface used on phones.
class TvPaywallContent extends StatelessWidget {
  const TvPaywallContent(
      {super.key,
      required this.state,
      required this.onSelect,
      required this.onPurchase,
      required this.onRetry,
      required this.onRestore,
      this.notice});
  final PaywallUiState state;
  final ValueChanged<String> onSelect;
  final VoidCallback onPurchase, onRetry, onRestore;
  final String? notice;

  String _ctaLabel(BuildContext context) {
    final l10n = context.l10n;
    if (state.billingState == PaywallBillingState.success)
      return l10n.paywallAccessActivated;
    if (state.productsState == PaywallProductsState.error)
      return tvText(context, 'Тарифы недоступны', 'Plans unavailable');
    if (state.productsState == PaywallProductsState.loading)
      return l10n.paywallLoadingPlans;
    if (state.externalCheckout) {
      if (state.isBusy) return l10n.paywallVerifyingPayment;
      if (state.externalReview) return l10n.paywallPaymentReviewShort;
      if (state.externalPending)
        return state.externalCanResume
            ? l10n.paywallResumeExternal
            : l10n.paywallVerifyingPayment;
      return state.externalSandbox
          ? l10n.paywallTestWataPayment
          : l10n.paywallPaySbp;
    }
    if (state.isBusy) return l10n.paywallVerifyingPayment;
    return l10n
        .paywallContinuePrice(state.selectedPlan?.formattedTotalPrice ?? '');
  }

  String _errorText(BuildContext context) => switch (state.errorKind) {
        PaywallErrorKind.storeUnavailable =>
          context.l10n.paywallStoreUnavailable,
        PaywallErrorKind.verificationFailed =>
          context.l10n.paywallVerificationFailed,
        PaywallErrorKind.restoreFailed => context.l10n.paywallRestoreFailed,
        PaywallErrorKind.countryUnavailable => tvText(
            context,
            'Не удалось определить регион подключения. Проверьте интернет и повторите.',
            'Could not determine your connection region. Check your internet and retry.'),
        PaywallErrorKind.regionalUnavailable => tvText(
            context,
            'Оплата временно недоступна. Попробуйте ещё раз.',
            'Payment is temporarily unavailable. Please retry.'),
        PaywallErrorKind.paymentConflict => tvText(
            context,
            'Сначала проверьте действующую подписку в аккаунте.',
            'Please check the active subscription in your account first.'),
        PaywallErrorKind.accountUnverified => tvText(
            context,
            'Для оплаты подтвердите почту аккаунта.',
            'Verify your account email before paying.'),
        PaywallErrorKind.launchFailed ||
        PaywallErrorKind.billingError =>
          context.l10n.paywallPaymentErrorOpen,
        _ => context.l10n.paywallProductsUnavailable,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final ready = state.productsState == PaywallProductsState.ready;
    final enabled = ready &&
        state.selectedPlan != null &&
        !state.isBusy &&
        !state.externalReview &&
        (!state.externalPending || state.externalCanResume) &&
        state.billingState != PaywallBillingState.success;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return SingleChildScrollView(
        child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaywallHeader(
            title: l10n.paywallChoosePlanTitle,
            subtitle: l10n.paywallChoosePlanSubtitle),
        const SizedBox(height: 24),
        if (state.productsState == PaywallProductsState.loading)
          const LinearProgressIndicator(),
        if (ready)
          for (var i = 0; i < state.plans.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            Builder(builder: (context) {
              final plan = state.plans[i];
              final title = switch (plan.periodMonths) {
                1 => l10n.paywallPlanOneMonth,
                6 => l10n.paywallPlanSixMonths,
                _ => l10n.paywallPlanTwelveMonths,
              };
              final savings = plan.savingsPercent == null
                  ? null
                  : l10n.paywallSavePercent(plan.savingsPercent!);
              return TvRemoteControl(
                  autofocus: i == 0,
                  onPressed: state.isBusy ? null : () => onSelect(plan.id),
                  child: TariffCard(
                      plan: plan,
                      selected: plan.id == state.selectedPlanId,
                      enabled: !state.isBusy,
                      title: title,
                      perMonthLabel: l10n.paywallPerMonth,
                      totalLabel: l10n.paywallTotal,
                      bestValueLabel: l10n.paywallBestValue,
                      savingsLabel: savings,
                      semanticsLabel: l10n.paywallTariffSemantics(
                          title,
                          plan.formattedMonthlyPrice,
                          plan.formattedTotalPrice,
                          savings ?? '',
                          plan.id == state.selectedPlanId
                              ? l10n.paywallSelected
                              : l10n.paywallNotSelected),
                      onSelected: () => onSelect(plan.id),
                      reducedMotion: reducedMotion));
            }),
          ],
        if (state.productsState == PaywallProductsState.error ||
            state.errorKind != null) ...[
          const SizedBox(height: 18),
          TvNotice(_errorText(context), error: true)
        ],
        if (notice != null) ...[const SizedBox(height: 18), TvNotice(notice!)],
        const SizedBox(height: 16),
        if (ready)
          TrustItems(
              googlePlay: state.externalCheckout
                  ? l10n.paywallTrustWata
                  : l10n.paywallTrustGooglePlay,
              noRenewals: l10n.paywallTrustNoRenewals,
              restore: l10n.paywallTrustRestore),
        const SizedBox(height: 16),
        TvRemoteControl(
            onPressed: enabled ? onPurchase : null,
            child: PremiumActionSurface(
                label: _ctaLabel(context),
                enabled: enabled,
                loading: state.isBusy,
                success: state.billingState == PaywallBillingState.success,
                pulseKey: state.selectedPlanId.hashCode,
                reducedMotion: reducedMotion,
                onPressed: onPurchase)),
        const SizedBox(height: 8),
        TvButton(
            label: l10n.paywallRestorePurchase,
            textOnly: true,
            onPressed: !ready ||
                    state.isBusy ||
                    state.billingState == PaywallBillingState.success
                ? null
                : onRestore),
        if (!ready)
          TvButton(
              label: l10n.paywallRetry,
              autofocus: state.productsState == PaywallProductsState.error,
              textOnly: true,
              onPressed: state.isBusy ? null : onRetry),
      ],
    ));
  }
}

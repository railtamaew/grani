import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golden_toolkit/golden_toolkit.dart';
import 'package:mobile_app/features/paywall/model/paywall_ui_state.dart';
import 'package:mobile_app/features/paywall/model/tariff_ui_model.dart';
import 'package:mobile_app/features/paywall/widgets/tariff_card.dart';
import 'package:mobile_app/features/paywall/widgets/premium_action_surface.dart';
import 'package:mobile_app/tv/tv_paywall_content.dart';
import 'package:mobile_app/tv/tv_ui.dart';
import 'tv_remote_test.dart' as qa;

List<TariffUiModel> plans() => [
      for (final months in [1, 6, 12])
        TariffUiModel(
            id: '${months}_months',
            productId: 'fixture_$months',
            periodMonths: months,
            periodDays: months * 30,
            formattedMonthlyPrice: '199 ₽',
            formattedTotalPrice: '${months * 199} ₽',
            priceMicros: months * 199000000,
            monthlyEquivalentMicros: 199000000,
            currencyCode: 'RUB',
            illustrationNeutral:
                'assets/images/tariffs/plan_token_${months}_neutral.png',
            illustrationSelected:
                'assets/images/tariffs/plan_token_${months}_selected.png',
            isBestValue: months == 12,
            savingsPercent: months == 12 ? 30 : null)
    ];

void main() {
  setUpAll(loadAppFonts);
  testWidgets('unavailable store explains the error and focuses Retry',
      (tester) async {
    var retries = 0;
    await tester.pumpWidget(qa.app(TvPage(
      title: '',
      child: TvPaywallContent(
        state: const PaywallUiState(
          productsState: PaywallProductsState.error,
          errorKind: PaywallErrorKind.storeUnavailable,
        ),
        onSelect: (_) {},
        onPurchase: () {},
        onRetry: () => retries++,
        onRestore: () {},
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Загрузка тарифов…'), findsNothing);
    expect(
        tester
            .widget<PremiumActionSurface>(find.byType(PremiumActionSurface))
            .label,
        'Тарифы недоступны');
    final notice = tester.widget<TvNotice>(find.byType(TvNotice));
    expect(notice.message, contains('Google Play'));
    final restore = tester.widget<TvButton>(find.byWidgetPredicate((widget) =>
        widget is TvButton && widget.label.contains('Восстановить')));
    expect(restore.onPressed, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(retries, 1);
  });
  for (final locale in ['ru', 'en']) {
    for (final scale in [1.0, 1.4]) {
      testWidgets(
          'mobile tariff cards fit TV in $locale at text scale $scale; remote selects and pays once',
          (tester) async {
        tester.view.physicalSize = const Size(960, 540);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        String? selected;
        var purchases = 0;
        var restores = 0;
        await tester.pumpWidget(qa.app(
            TvPage(
                title: '',
                contentWidth: 460,
                child: TvPaywallContent(
                    state: PaywallUiState(
                        productsState: PaywallProductsState.ready,
                        plans: plans(),
                        selectedPlanId: '12_months'),
                    onSelect: (id) => selected = id,
                    onPurchase: () => purchases++,
                    onRetry: () {},
                    onRestore: () => restores++)),
            locale: locale,
            scale: scale));
        await tester.pumpAndSettle();
        expect(find.byType(TariffCard), findsNWidgets(3));
        expect(find.byType(PremiumActionSurface), findsOneWidget);
        expect(tester.takeException(), isNull);
        await qa.screenshot(tester, 'plans-$locale-$scale');
        await qa.key(tester, LogicalKeyboardKey.select);
        expect(selected, '1_months');
        await qa.key(tester, LogicalKeyboardKey.arrowDown);
        await qa.key(tester, LogicalKeyboardKey.select);
        expect(selected, '6_months');
        await qa.key(tester, LogicalKeyboardKey.arrowDown);
        await qa.key(tester, LogicalKeyboardKey.select);
        expect(selected, '12_months');
        await qa.key(tester, LogicalKeyboardKey.arrowDown);
        await qa.screenshot(tester, 'plans-cta-$locale-$scale');
        await qa.key(tester, LogicalKeyboardKey.select);
        expect(purchases, 1);
        await qa.key(tester, LogicalKeyboardKey.arrowDown);
        await qa.key(tester, LogicalKeyboardKey.select);
        expect(restores, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/features/paywall/model/paywall_ui_state.dart';
import 'package:mobile_app/tv/tv_paywall_content.dart';
import 'package:mobile_app/tv/tv_ui.dart';
import 'tv_remote_test.dart' as qa;

void main() {
  testWidgets(
      'unknown region offers retry without claiming Google or a purchase',
      (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var retries = 0;
    var purchases = 0;
    await tester.pumpWidget(qa.app(TvPage(
        title: '',
        contentWidth: 460,
        child: TvPaywallContent(
            state: const PaywallUiState(
                productsState: PaywallProductsState.error,
                billingState: PaywallBillingState.error,
                errorKind: PaywallErrorKind.countryUnavailable),
            onSelect: (_) {},
            onPurchase: () {
              purchases++;
            },
            onRetry: () {
              retries++;
            },
            onRestore: () {}))));
    await tester.pumpAndSettle();
    expect(find.textContaining('Google Play'), findsNothing);
    expect(find.textContaining('Не удалось определить регион'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(retries, 1);
    expect(purchases, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

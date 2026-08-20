import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/features/paywall/widgets/paywall_top_bar.dart';

void main() {
  Widget harness(VoidCallback? onBack) {
    return MaterialApp(
      home: Scaffold(body: PaywallTopBar(onBack: onBack)),
    );
  }

  testWidgets('mandatory paywall does not render a back action',
      (tester) async {
    await tester.pumpWidget(harness(null));

    expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsNothing);
    expect(find.byType(IconButton), findsNothing);
  });

  testWidgets('optional paywall keeps a working back action', (tester) async {
    var taps = 0;
    await tester.pumpWidget(harness(() => taps++));

    final back = find.byIcon(Icons.arrow_back_ios_new_rounded);
    expect(back, findsOneWidget);
    await tester.tap(back);
    expect(taps, 1);
  });
}

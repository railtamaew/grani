import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/widgets/pin_code_input.dart';

void main() {
  Future<void> pumpPin(
    WidgetTester tester, {
    required double viewportWidth,
    required double availableWidth,
    bool isError = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: Size(viewportWidth, 800)),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: availableWidth,
                child: PinCodeInput(
                  scaleX: viewportWidth / 412,
                  scaleY: 800 / 917,
                  autoFocus: false,
                  isError: isError,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('four PIN slots fit the real parent width on a 412px screen',
      (tester) async {
    // AuthCodeScreen: 412 - 2*32 outer padding - 2*20 card padding = 308.
    // The former fixed layout requested 310px and painted a yellow/black
    // RenderFlex overflow stripe at the fourth field.
    await pumpPin(
      tester,
      viewportWidth: 412,
      availableWidth: 308,
    );

    expect(find.byType(TextField), findsNWidgets(4));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(Row)).width, lessThanOrEqualTo(308));
  });

  testWidgets('PIN remains overflow-free after all four digits are entered',
      (tester) async {
    await pumpPin(
      tester,
      viewportWidth: 360,
      availableWidth: 269,
    );

    for (var index = 0; index < 4; index++) {
      await tester.enterText(find.byType(TextField).at(index), '${index + 1}');
      await tester.pump();
    }

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(Row)).width, lessThanOrEqualTo(269));
  });
}

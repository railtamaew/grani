import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Минимальный smoke-тест без main.dart (Firebase/GetIt не нужны).
void main() {
  testWidgets('smoke: MaterialApp mounts', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Text('ok'),
        ),
      ),
    );
    expect(find.text('ok'), findsOneWidget);
  });
}

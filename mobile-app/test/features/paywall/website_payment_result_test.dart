import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mobile_app/features/paywall/controller/website_payment_result_controller.dart';
import 'package:mobile_app/models/user.dart';
import 'package:mobile_app/screens/website_payment_result_screen.dart';
import 'package:mobile_app/services/auth_service.dart';
import 'package:mobile_app/services/regional_checkout_service.dart';
import 'regional_checkout_test.dart' show checkoutJson, orderId;

class ResultAuth extends Mock implements AuthService {}

void main() {
  late ResultAuth auth;
  late WebsitePaymentResultController controller;
  late String status;
  late String state;
  late bool offline;
  late bool active;
  late User user;
  late int countryReads;
  late int creates;
  late int acknowledgements;
  setUp(() {
    auth = ResultAuth();
    status = 'pending';
    state = 'awaiting_payment';
    offline = false;
    active = true;
    countryReads = 0;
    creates = 0;
    acknowledgements = 0;
    user = User(
        id: '954',
        email: 'test@example.test',
        isEmailVerified: true,
        createdAt: DateTime(2026),
        isBlocked: false);
    when(() => auth.user).thenAnswer((_) => user);
    when(() => auth.isAuthenticated).thenReturn(true);
    when(() => auth.trialSecondsLeft).thenReturn(0);
    when(() => auth.hasActiveSubscription).thenAnswer((_) => active);
    when(() => auth.refreshUserStatus(force: true)).thenAnswer((_) async {});
    controller = WebsitePaymentResultController(
        auth: auth,
        service: RegionalCheckoutService(
          loadIntent: () async => orderId,
          loadReturnOrder: () async => null,
          saveReturnOrder: (_) async {},
          saveIntent: (_) async {
            acknowledgements++;
          },
          readCountry: () async {
            countryReads++;
            throw StateError('Billing unavailable');
          },
          request: (path, body) async {
            if (body != null) creates++;
            if (offline) throw StateError('network unavailable');
            return {
              'intent_id': orderId,
              'state': state,
              'duration_days': 30,
              'amount_minor': 39900,
              'current_paid_until': '2026-11-29T12:00:00Z',
              if (status == 'paid')
                'order_access_until': '2026-12-29T12:00:00Z',
              'order': checkoutJson(status: status, environment: 'production')
            };
          },
        ));
  });
  tearDown(() => controller.dispose());

  test(
      'existing access never confirms the current order and needs no Play lookup',
      () async {
    await controller.refresh();
    expect(controller.order!.id, orderId);
    expect(controller.paid, isFalse);
    expect(controller.context!['duration_days'], 30);
    expect(countryReads, 0);
    expect(creates, 0);
    await controller.acknowledgeCompleted();
    expect(acknowledgements, 0);
  });
  test('paid order with pending access sync is still processing', () async {
    status = 'paid';
    state = 'updating_access';
    await controller.refresh();
    expect(controller.updatingAccess, isTrue);
    expect(controller.paid, isFalse);
    await controller.acknowledgeCompleted();
    expect(acknowledgements, 0);
  });
  test(
      'only exact completed payment and refreshed access allow acknowledgement',
      () async {
    status = 'paid';
    state = 'completed';
    active = false;
    await controller.refresh();
    expect(controller.paid, isTrue);
    await controller.acknowledgeCompleted();
    expect(acknowledgements, 0);
    active = true;
    await controller.refresh();
    await controller.acknowledgeCompleted();
    expect(acknowledgements, 1);
    expect(countryReads, 0);
    expect(creates, 0);
  });
  test('temporary failure keeps the exact unpaid order without granting access',
      () async {
    await controller.refresh();
    offline = true;
    await controller.refresh();
    expect(controller.failed, isTrue);
    expect(controller.order!.id, orderId);
    expect(controller.paid, isFalse);
    expect(creates, 0);
  });
  test('account switch cannot render or acknowledge another account result',
      () async {
    await controller.refresh();
    user = User(
        id: '955',
        email: 'other@example.test',
        isEmailVerified: true,
        createdAt: DateTime(2026),
        isBlocked: false);
    await controller.refresh();
    expect(controller.context, isNull);
    expect(controller.order, isNull);
    await controller.acknowledgeCompleted();
    expect(acknowledgements, 0);
  });
  testWidgets(
      'result screen shows the owned purchase and returns to main without login',
      (tester) async {
    await controller.refresh();
    await tester.pumpWidget(MaterialApp(
      home: WebsitePaymentResultScreen(controller: controller),
      routes: {'/main': (_) => const Scaffold(body: Text('MAIN'))},
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('Payment not confirmed'), findsOneWidget);
    expect(find.text('Purchase: 30 days'), findsOneWidget);
    expect(find.textContaining('Current access:'), findsOneWidget);
    expect(find.textContaining('Google Play'), findsNothing);
    expect(find.text('Payment confirmed'), findsNothing);
    await tester.tap(find.text('Return to GRANI'));
    await tester.pumpAndSettle();
    expect(find.text('MAIN'), findsOneWidget);
    expect(countryReads, 0);
    expect(creates, 0);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'completed payment has an explicit activation result and preserves exact date',
      (tester) async {
    status = 'paid';
    state = 'completed';
    await controller.refresh();
    await tester.pumpWidget(
        MaterialApp(home: WebsitePaymentResultScreen(controller: controller)));
    await tester.pump();
    await tester.pump();
    expect(find.text('Premium activated'), findsOneWidget);
    expect(find.text('Done — 30 days added.'), findsOneWidget);
    expect(find.textContaining('Access after this purchase:'), findsOneWidget);
    expect(find.text('Check payment'), findsNothing);
    expect(countryReads, 0);
    await tester.pumpWidget(const SizedBox());
  });
}

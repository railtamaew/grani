import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_app/l10n/app_localizations.dart';
import 'package:mobile_app/screens/start_screen.dart';
import 'package:mobile_app/screens/referrals_screen.dart';
import 'package:mobile_app/services/auth_service.dart';
import 'package:mobile_app/services/referral_service.dart';
import 'package:mobile_app/core/storage/shared_preferences_holder.dart';

class SessionAuth extends ChangeNotifier implements AuthService {
  SessionAuth(String? account) {
    setAccount(account);
  }
  String? _token;
  void setAccount(String? account) {
    _token = account == null
        ? null
        : 'header.${base64Url.encode(utf8.encode(jsonEncode({'sub': account})))}.signature';
    notifyListeners();
  }

  @override
  String? get token => _token;
  @override
  bool get isAuthenticated => _token != null;
  @override
  bool get hasActiveSubscription => true;
  @override
  bool get isLoading => false;
  @override
  Future<void> waitForTokenLoad() async {}
  @override
  Future<bool> ensureValidToken() async => true;
  @override
  Future<void> refreshUserStatus({bool force = false}) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget app(SessionAuth auth, Widget home) =>
    ChangeNotifierProvider<AuthService>.value(
      value: auth,
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        routes: {
          '/main': (_) => const Scaffold(body: Text('AUTHENTICATED HOME')),
        },
        home: home,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => SharedPreferences.setMockInitialValues({}));
  setUp(() async => (await getSharedPreferences()).clear());
  testWidgets('already-open welcome reacts to completed sign-in', (
    tester,
  ) async {
    final auth = SessionAuth(null);
    await tester.pumpWidget(app(auth, const StartScreen()));
    await tester.pumpAndSettle();
    auth.setAccount('1');
    await tester.pumpAndSettle();
    expect(find.text('AUTHENTICATED HOME'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('late response from previous account cannot restore its gift', (
    tester,
  ) async {
    final auth = SessionAuth('1');
    final first = Completer<http.Response>();
    var requests = 0;
    final service = ReferralService.test(
      MockClient((request) async {
        requests++;
        if (requests == 1) return first.future;
        return http.Response(
          jsonEncode({
            'eligibility': {'eligible': true},
            'received': null,
          }),
          200,
        );
      }),
    );
    await tester.pumpWidget(
      app(
        auth,
        ReferralsScreen(service: service, mode: GiftScreenMode.receive),
      ),
    );
    await tester.pump();
    await tester.pump();
    auth.setAccount('2');
    await tester.pump();
    await tester.pump();
    first.complete(
      http.Response(
        jsonEncode({
          'received': {
            'status': 'pending',
            'trial_expires_at': '2030-01-09T15:00:00Z',
            'reward_days': 3,
          },
        }),
        200,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Gift activated'), findsNothing);
    expect(find.text('Have a friend’s invitation?'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

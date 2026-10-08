import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:provider/provider.dart';
import 'package:mobile_app/l10n/app_localizations.dart';
import 'package:mobile_app/screens/start_screen.dart';
import 'package:mobile_app/services/auth_service.dart';
import 'package:mobile_app/core/storage/shared_preferences_holder.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeAuth extends Mock implements AuthService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => SharedPreferences.setMockInitialValues({}));
  for (final scenario in [
    'ordinary',
    'pending_invitation',
    'covered_welcome'
  ]) {
    testWidgets('welcome fallback respects $scenario', (tester) async {
      final prefs = await getSharedPreferences();
      await prefs.clear();
      if (scenario == 'pending_invitation') {
        await prefs.setString(
            'grani_pending_app_link_route_v1', '/gift/receive');
      }
      tester.view.physicalSize = const Size(412, 917);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final ready = Completer<void>();
      final auth = FakeAuth();
      when(() => auth.waitForTokenLoad()).thenAnswer((_) => ready.future);
      when(() => auth.isAuthenticated).thenReturn(true);
      when(() => auth.isLoading).thenReturn(false);
      when(() => auth.token).thenReturn('test');
      when(() => auth.hasActiveSubscription).thenReturn(true);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(ChangeNotifierProvider<AuthService>.value(
        value: auth,
        child: MaterialApp(
          navigatorKey: navigator,
          initialRoute: '/',
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          routes: {
            '/': (_) => const StartScreen(),
            '/gift/receive': (_) => const Scaffold(body: Text('GIFT TARGET')),
            '/main': (_) => const Scaffold(body: Text('HOME TARGET')),
          },
        ),
      ));
      await tester.pump();
      if (scenario == 'covered_welcome') {
        navigator.currentState!.pushNamed('/gift/receive');
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
      }
      ready.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(scenario == 'ordinary' ? 'HOME TARGET' : 'GIFT TARGET'),
          findsOneWidget);
      expect(find.text(scenario == 'ordinary' ? 'GIFT TARGET' : 'HOME TARGET'),
          findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

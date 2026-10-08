import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_app/services/auth_service.dart';
import 'package:mobile_app/services/referral_service.dart';
import 'package:mobile_app/core/storage/shared_preferences_holder.dart';
import 'package:mobile_app/screens/referrals_screen.dart';
import 'package:mobile_app/l10n/app_localizations.dart';
import 'package:mobile_app/theme.dart';
import 'package:mobile_app/widgets/grani_gift_art.dart';

class FakeAuth extends Mock implements AuthService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    for (final family in ['Montserrat', 'GraniGiftMontserrat']) {
      final loader = FontLoader(family)
        ..addFont(
            rootBundle.load('assets/fonts/GraniGiftMontserrat-Regular.ttf'))
        ..addFont(
          rootBundle.load('assets/fonts/GraniGiftMontserrat-SemiBold.ttf'),
        )
        ..addFont(rootBundle.load('assets/fonts/GraniGiftMontserrat-Bold.ttf'));
      await loader.load();
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  setUp(() async => (await getSharedPreferences()).clear());
  Map<String, dynamic> state() => {
        'enabled': true,
        'share_url': 'https://granilink.com/r/ABCD2345EFGH',
        'reward_days': 4,
        'monthly_limit': 5,
        'claim_policy': 'first_trial',
        'rewards_remaining': 5,
        'bonus_seconds': 0,
        'received': null,
        'eligibility': {'eligible': true},
        'history': [],
      };
  Future<void> show(
    WidgetTester tester,
    String language,
    GiftScreenMode mode,
    ReferralService service, {
    bool signedIn = true,
    double scale = 1.4,
    double width = 320,
    GlobalKey? captureKey,
  }) async {
    tester.view.physicalSize = Size(width, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = FakeAuth();
    when(() => auth.isAuthenticated).thenReturn(signedIn);
    when(() => auth.token).thenReturn(signedIn ? 'test' : null);
    when(() => auth.ensureValidToken()).thenAnswer((_) async => true);
    when(() => auth.refreshUserStatus(force: true)).thenAnswer((_) async {});
    await tester.pumpWidget(
      ChangeNotifierProvider<AuthService>.value(
        value: auth,
        child: MaterialApp(
          theme: GraniTheme.theme,
          locale: Locale(language),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: RepaintBoundary(
            key: captureKey,
            child: ReferralsScreen(service: service, mode: mode),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final language in ['ru', 'en']) {
    testWidgets(
      'network retry keeps invitation and celebrates once $language',
      (tester) async {
        var claims = 0;
        final service = ReferralService.test(
          MockClient((request) async {
            if (request.url.path.endsWith('/claim')) {
              claims++;
              return claims == 1
                  ? http.Response('{"detail":"unavailable"}', 503)
                  : http.Response('{}', 200);
            }
            final data = state();
            if (claims > 1) {
              data['received'] = {
                'status': 'pending',
                'reward_days': 3,
                'trial_expires_at': '2030-01-09T15:00:00Z',
              };
            }
            return http.Response(jsonEncode(data), 200);
          }),
        );
        await service.capture('ABCD2345EFGH');
        await show(tester, language, GiftScreenMode.receive, service);
        expect(await service.pendingCode(), 'ABCD2345EFGH');
        expect(find.byType(TextField), findsNothing);
        final retry = find.text(
          language == 'ru' ? 'Повторить проверку' : 'Try again',
        );
        await tester.ensureVisible(retry);
        await tester.tap(retry);
        await tester.pumpAndSettle();
        expect(claims, 2);
        expect(await service.pendingCode(), isNull);
        expect(
          find.text(
            language == 'ru' ? 'Подарок активирован' : 'Gift activated',
          ),
          findsOneWidget,
        );
        expect(
          tester.widget<GraniGiftArt>(find.byType(GraniGiftArt)).animate,
          true,
        );
        await tester.pumpWidget(const SizedBox());
        await show(tester, language, GiftScreenMode.receive, service);
        expect(claims, 2);
        expect(
          tester.widget<GraniGiftArt>(find.byType(GraniGiftArt)).animate,
          false,
        );
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets('sender has one task and fits large text $language', (
      tester,
    ) async {
      final service = ReferralService.test(
        MockClient((_) async => http.Response(jsonEncode(state()), 200)),
      );
      await show(tester, language, GiftScreenMode.send, service);
      expect(find.byType(TextField), findsNothing);
      expect(
        find.textContaining(
          language == 'ru' ? 'Вам — 4' : '4 bonus days for you',
        ),
        findsOneWidget,
      );
      final label = language == 'ru' ? 'Отправить подарок' : 'Send a gift';
      await tester.scrollUntilVisible(find.text(label), 200);
      final rect = tester.getRect(find.widgetWithText(FilledButton, label));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(320));
      expect(rect.height, greaterThanOrEqualTo(56));
      expect(tester.takeException(), isNull);
    });
    testWidgets('manual claim rejection stays visible $language', (
      tester,
    ) async {
      var claims = 0;
      final service = ReferralService.test(
        MockClient((request) async {
          if (request.url.path.endsWith('/claim')) {
            claims++;
            return http.Response(
              jsonEncode({
                'error': {'message': 'invalid_code'},
              }),
              409,
            );
          }
          return http.Response(jsonEncode(state()), 200);
        }),
      );
      await show(tester, language, GiftScreenMode.receive, service);
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'INVALID01');
      await tester.pump();
      final apply = find.text(
        language == 'ru' ? 'Применить код' : 'Apply code',
      );
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(claims, 1);
      expect(
        find
            .text(
              language == 'ru'
                  ? 'Проверьте код приглашения.'
                  : 'Check your invitation code.',
            )
            .hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
    testWidgets(
      'automatic rejection has a reason and no sender pitch $language',
      (tester) async {
        final data = state()
          ..['eligibility'] = {
            'eligible': false,
            'reason': 'existing_customer',
          };
        final service = ReferralService.test(
          MockClient(
            (request) async => request.url.path.endsWith('/claim')
                ? http.Response('{"detail":"existing_customer"}', 409)
                : http.Response(jsonEncode(data), 200),
          ),
        );
        await service.capture('ABCD2345EFGH');
        await show(tester, language, GiftScreenMode.receive, service);
        expect(
          find.text(
            language == 'ru'
                ? 'Этот подарок предназначен для новых пользователей.'
                : 'This gift is for new users.',
          ),
          findsOneWidget,
        );
        expect(find.byType(TextField), findsNothing);
        expect(
          find.text(language == 'ru' ? 'Отправить подарок' : 'Send a gift'),
          findsNothing,
        );
        expect(await service.pendingCode(), isNull);
        expect(
          tester
              .widgetList<GraniGiftArt>(find.byType(GraniGiftArt))
              .every((art) => !art.animate),
          true,
        );
        expect(
          find.text(
            language == 'ru'
                ? 'Подарок недоступен этому аккаунту'
                : 'This account cannot receive a gift',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'received gift shows exact expiry and legacy reward $language',
      (tester) async {
        final data = state()
          ..['received'] = {
            'status': 'pending',
            'reward_days': 3,
            'trial_expires_at': '2030-01-09T15:00:00Z',
          };
        final service = ReferralService.test(
          MockClient((_) async => http.Response(jsonEncode(data), 200)),
        );
        await show(tester, language, GiftScreenMode.receive, service);
        expect(find.textContaining('2030'), findsOneWidget);
        expect(
          find.textContaining(
            language == 'ru' ? '3 бонусных дня' : '3 bonus days',
          ),
          findsOneWidget,
        );
        expect(find.byType(TextField), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'renewing subscription explains that saved bonuses wait $language',
      (tester) async {
        final data = state()
          ..['bonus_seconds'] = 345600
          ..['bonus_usage'] = 'after_renewal_stops'
          ..['bonus_starts_at'] = '2030-01-09T15:00:00Z';
        final service = ReferralService.test(
          MockClient((_) async => http.Response(jsonEncode(data), 200)),
        );
        await show(tester, language, GiftScreenMode.bonuses, service);
        expect(
          find.textContaining(
            language == 'ru'
                ? 'Пока подписка продлевается'
                : 'Bonuses wait while it renews',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('2030'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final language in ['ru', 'en']) {
    testWidgets(
      'empty receipt has no deadline or activation promise $language',
      (tester) async {
        final data = state()
          ..['eligibility'] = {
            'eligible': true,
            'claim_before': '2030-01-09T15:00:00Z',
          };
        final service = ReferralService.test(
          MockClient((_) async => http.Response(jsonEncode(data), 200)),
        );
        await show(tester, language, GiftScreenMode.receive, service);
        expect(
          find.text(
            language == 'ru'
                ? 'Есть приглашение от друга?'
                : 'Have a friend’s invitation?',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('2030'), findsNothing);
        final button = tester.widget<FilledButton>(
          find.widgetWithText(
            FilledButton,
            language == 'ru' ? 'Применить код' : 'Apply code',
          ),
        );
        expect(button.onPressed, isNull);
        expect(
          tester
              .widget<TextField>(find.byType(TextField))
              .decoration!
              .counterText,
          '',
        );
        expect(
          tester
              .widgetList<GraniGiftArt>(find.byType(GraniGiftArt))
              .every((art) => !art.animate),
          true,
        );
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'own invitation is recoverable only when account allows it $language',
      (tester) async {
        for (final allowed in [true, false]) {
          final data = state()
            ..['eligibility'] = {
              'eligible': allowed,
              'reason': allowed ? null : 'existing_customer',
            };
          final service = ReferralService.test(
            MockClient(
              (r) async => r.url.path.endsWith('/claim')
                  ? http.Response('{"detail":"self_referral"}', 409)
                  : http.Response(jsonEncode(data), 200),
            ),
          );
          await service.capture('ABCD2345EFGH');
          await show(tester, language, GiftScreenMode.receive, service);
          expect(
            find.text(
              language == 'ru'
                  ? 'Это ваше приглашение'
                  : 'This is your invitation',
            ),
            findsOneWidget,
          );
          expect(find.byType(TextField), findsNothing);
          expect(
            find.text(
              language == 'ru'
                  ? 'Ввести код от другого друга'
                  : 'Enter another friend’s code',
            ),
            allowed ? findsOneWidget : findsNothing,
          );
          expect(
            tester
                .widgetList<GraniGiftArt>(find.byType(GraniGiftArt))
                .every((art) => !art.animate),
            true,
          );
          await tester.pumpWidget(const SizedBox());
          await (await getSharedPreferences()).clear();
        }
      },
    );
    testWidgets('unauthorized invitation is not a granted gift $language', (
      tester,
    ) async {
      final service = ReferralService.test(
        MockClient(
          (_) async => http.Response('{"available":true,"reward_days":3}', 200),
        ),
      );
      await service.capture('ABCD2345EFGH');
      await show(
        tester,
        language,
        GiftScreenMode.receive,
        service,
        signedIn: false,
      );
      expect(
        find.text(
          language == 'ru'
              ? 'Вам прислали приглашение'
              : 'You have an invitation',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          language == 'ru' ? 'Вам подарили 7' : 'You received 7',
        ),
        findsNothing,
      );
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    });
    testWidgets(
      'stale account deadline blocks form and celebration $language',
      (tester) async {
        final data = state()
          ..['eligibility'] = {
            'eligible': true,
            'claim_before': '2000-01-01T00:00:00Z',
          };
        final service = ReferralService.test(
          MockClient((_) async => http.Response(jsonEncode(data), 200)),
        );
        await show(tester, language, GiftScreenMode.receive, service);
        expect(find.byType(TextField), findsNothing);
        expect(find.textContaining('2000'), findsNothing);
        expect(
          find.text(
            language == 'ru'
                ? 'Подарок недоступен этому аккаунту'
                : 'This account cannot receive a gift',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'prepaid bonuses explain extension without billing date $language',
      (tester) async {
        final data = state()
          ..addAll({
            'bonus_seconds': 518400,
            'bonus_usage': 'after_paid_access',
            'subscription_auto_renew': false,
            'bonus_starts_at': '2030-11-04T12:00:00Z',
            'bonus_expires_at': '2030-11-10T12:00:00Z',
            'received': {'trial_expires_at': '2030-01-01T00:00:00Z'},
          });
        final service = ReferralService.test(
          MockClient((_) async => http.Response(jsonEncode(data), 200)),
        );
        await show(tester, language, GiftScreenMode.bonuses, service);
        expect(
          find.textContaining(
            language == 'ru' ? 'Дата списания' : 'billing date',
          ),
          findsNothing,
        );
        expect(
          find.text(language == 'ru' ? 'История начислений' : 'Reward history'),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            language == 'ru'
                ? 'не входит в этот баланс'
                : 'separate from this balance',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  test('remaining time never rounds up and Russian days are declined', () {
    expect(giftDuration(0, true), '0 дней');
    expect(giftDuration(86400, true), '1 день');
    expect(giftDuration(345600, true), '4 дня');
    expect(giftDuration(950400, true), '11 дней');
    expect(giftDuration(86399, true), '23 ч 59 мин');
    expect(giftDuration(30, true), 'Меньше минуты');
  });
  testWidgets('pasting a code enables an explicit application', (tester) async {
    final service = ReferralService.test(
      MockClient((_) async => http.Response(jsonEncode(state()), 200)),
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? {'text': ' abcd2345efgh '}
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await show(tester, 'en', GiftScreenMode.receive, service);
    final paste = find.text('Paste code');
    await tester.ensureVisible(paste);
    await tester.tap(paste);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'ABCD2345EFGH',
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Apply code'))
          .onPressed,
      isNotNull,
    );
    expect(await service.pendingCode(), isNull);
  });
  testWidgets('capture empty, own and denied account states', (tester) async {
    for (final name in ['empty', 'own', 'denied']) {
      await (await getSharedPreferences()).clear();
      final data = state();
      if (name == 'denied') {
        data['eligibility'] = {
          'eligible': false,
          'reason': 'claim_window_expired',
          'claim_before': '2000-01-01T00:00:00Z',
        };
      }
      final service = ReferralService.test(
        MockClient(
          (request) async => request.url.path.endsWith('/claim')
              ? http.Response('{"detail":"self_referral"}', 409)
              : http.Response(jsonEncode(data), 200),
        ),
      );
      if (name == 'own') await service.capture('ABCD2345EFGH');
      final key = GlobalKey();
      await show(
        tester,
        'ru',
        GiftScreenMode.receive,
        service,
        scale: 1,
        width: 400,
        captureKey: key,
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('qa').create(recursive: true);
        await File(
          'qa/gift-$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
  });
  testWidgets('capture sender receiver and bonus previews', (tester) async {
    for (final (language, mode) in [
      for (final language in ['ru', 'en'])
        for (final mode in GiftScreenMode.values) (language, mode),
    ]) {
      final data = state()..['reward_days'] = 3;
      if (mode == GiftScreenMode.receive)
        data['received'] = {
          'status': 'pending',
          'reward_days': 3,
          'trial_expires_at': '2030-01-09T15:00:00Z',
        };
      if (mode == GiftScreenMode.bonuses)
        data.addAll({
          'bonus_seconds': 518400,
          'bonus_usage': 'after_paid_access',
          'subscription_auto_renew': false,
          'bonus_starts_at': '2030-11-04T12:00:00Z',
          'bonus_expires_at': '2030-11-10T12:00:00Z',
          'history': [
            {
              'status': 'rewarded',
              'reward_days': 3,
              'accepted_at': '2026-10-02T09:00:00Z',
            },
            {
              'status': 'rewarded',
              'reward_days': 3,
              'accepted_at': '2026-10-05T09:00:00Z',
            },
          ],
        });
      final service = ReferralService.test(
        MockClient((_) async => http.Response(jsonEncode(data), 200)),
      );
      final key = GlobalKey();
      await show(
        tester,
        language,
        mode,
        service,
        scale: 1,
        width: 400,
        captureKey: key,
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('qa').create(recursive: true);
        await File(
          'qa/gift-$language-${mode.name}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox());
    }
  });
}

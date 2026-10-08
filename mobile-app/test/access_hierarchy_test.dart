import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mobile_app/models/profile_access_snapshot.dart';
import 'package:mobile_app/widgets/profile/grani_access_avatar.dart';
import 'package:mobile_app/widgets/profile/access_avatar_policy.dart';
import 'package:mobile_app/widgets/profile/grani_menu_sections.dart';
import 'profile_menu_ux_test.dart' as qa;
import 'grani_avatar_test.dart' as motionQa;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await initializeDateFormatting('ru');
    final text = FontLoader('Montserrat')
      ..addFont(rootBundle.load('assets/fonts/GraniGiftMontserrat-Regular.ttf'))
      ..addFont(
          rootBundle.load('assets/fonts/GraniGiftMontserrat-SemiBold.ttf'))
      ..addFont(rootBundle.load('assets/fonts/GraniGiftMontserrat-Bold.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait([text.load(), icons.load()]);
  });
  final now = DateTime.utc(2026, 10, 5, 9);
  ProfileAccessSnapshot paid(int months, {bool ended = false}) =>
      ProfileAccessSnapshot.fromPayload({
        'hasActiveSubscription': !ended,
        'trialSecondsLeft': 0,
        'subscription_source': 'wata_sbp',
        'subscription_started_at': '2026-10-01T09:00:00Z',
        'subscription_expires_at': '2026-10-31T09:00:00Z',
        'subscription_auto_renew': false,
        'paid_access_elapsed_seconds': months * 30 * 86400,
      }, now: now);

  test('earned paid avatar thresholds require elapsed months', () {
    for (final entry
        in {0: 0, 1: 1, 2: 1, 3: 2, 5: 2, 6: 3, 11: 3, 12: 4, 24: 4}.entries) {
      expect(paid(entry.key).avatarTier, entry.value);
    }
    final prepaid = ProfileAccessSnapshot.fromPayload({
      'hasActiveSubscription': true,
      'subscription_expires_at': '2027-10-05T09:00:00Z',
      'paid_access_elapsed_seconds': 2 * 86400,
    }, now: now);
    expect(prepaid.avatarTier, 0);
    expect(prepaid.paidMonths, 0);
    expect(ProfileAccessSnapshot.fromJson(paid(6).toJson()).paidMonths, 6);
  });
  test(
      'ribbon uses remaining fraction of trial, purchase or bonus, not account age',
      () {
    final trial = ProfileAccessSnapshot.fromPayload({
      'trialSecondsLeft': 3600,
      'trialTotalSeconds': 7200,
      'hasActiveSubscription': false
    }, now: now);
    expect(trial.remainingFractionAt(now), .5);
    expect(
        trial.remainingFractionAt(now.add(const Duration(minutes: 30))), .25);
    expect(paid(3).remainingFractionAt(now), closeTo(26 / 30, .001));
    final bonus = ProfileAccessSnapshot.fromPayload({
      'trialSecondsLeft': 0,
      'hasActiveSubscription': true,
      'subscription_source': 'referral_bonus',
      'subscription_expires_at': '2026-10-07T09:00:00Z',
      'bonus_starts_at': '2026-10-04T09:00:00Z'
    }, now: now);
    expect(bonus.remainingFractionAt(now), closeTo(2 / 3, .001));
    expect(ProfileAccessSnapshot(capturedAt: now).remainingFractionAt(now),
        isNull);
  });
  test('old snapshot cache safely lacks new duration/tenure fields', () {
    final value = ProfileAccessSnapshot.fromJson({
      'known': true,
      'active': false,
      'trial_expires_at': '2026-10-06T09:00:00Z'
    });
    expect(value.remainingFractionAt(now), isNull);
    expect(value.paidMonths, isNull);
  });
  for (final language in ['ru', 'en']) {
    for (final months in [0, 1, 3, 6, 12]) {
      testWidgets(
          'earned avatar $months months and premium hierarchy $language',
          (tester) async {
        final access = paid(months);
        await tester.pumpWidget(qa.harness(
            GraniAccessCard(access: access, now: now, onPlan: () {}),
            language: language,
            width: 282,
            scale: 1.4));
        expect(find.byType(GraniAccessAvatar), findsOneWidget);
        expect(
            find.byKey(
                ValueKey('avatar--${accessAvatarType(access, now)!.name}')),
            findsOneWidget);
        expect(
            tester
                .widget<LinearProgressIndicator>(
                    find.byKey(const ValueKey('profile-access-progress')))
                .value,
            closeTo(26 / 30, .001));
        expect(find.text('Premium'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(qa.harness(
            GraniAccessCard(access: access, now: now, onPlan: () {}),
            language: language));
        await motionQa.loaded(tester, accessAvatarType(access, now)!);
        await tester.pumpAndSettle();
        await qa.preview(tester, 'access-premium-$months-$language');
      });
    }
    testWidgets('trial has its own status without a new ribbon $language',
        (tester) async {
      final trial = ProfileAccessSnapshot.fromPayload({
        'trialSecondsLeft': 2 * 86400,
        'trialTotalSeconds': 3 * 86400,
        'paid_access_elapsed_seconds': 0,
        'hasActiveSubscription': false
      }, now: now);
      await tester.pumpWidget(qa.harness(
          GraniAccessCard(access: trial, now: now, onPlan: () {}),
          language: language));
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text(language == 'ru' ? 'Пробный доступ' : 'Trial access'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
      await motionQa.loaded(tester, accessAvatarType(trial, now)!);
      await qa.preview(tester, 'access-trial-$language');
    });
  }
  testWidgets(
      'earned avatar stays after expiry without claiming active Premium',
      (tester) async {
    final access = paid(12, ended: true);
    await tester.pumpWidget(
        qa.harness(GraniAccessCard(access: access, now: now, onPlan: () {})));
    expect(find.byKey(const ValueKey('avatar--master')), findsOneWidget);
    expect(find.text('Доступ не активен'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

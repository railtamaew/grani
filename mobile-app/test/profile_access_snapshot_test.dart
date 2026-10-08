import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import '../lib/models/profile_access_snapshot.dart';

void main() {
  final start = DateTime.utc(2026, 10, 5, 9);
  ProfileAccessSnapshot parse(Map<String, dynamic> value) =>
      ProfileAccessSnapshot.fromPayload(value, now: start);
  test('backend bonus subscription-like access is never a paid subscription',
      () {
    final value = parse({
      'trialSecondsLeft': 0,
      'hasActiveSubscription': true,
      'subscription_source': 'referral_bonus',
      'subscription_expires_at': '2026-10-08T12:59:13.682262',
      'subscription_auto_renew': false
    });
    expect(value.kindAt(start), ProfileAccessKind.bonus);
    expect(value.expiresAt(start),
        DateTime.utc(2026, 10, 8, 12, 59, 13, 682, 262));
  });
  test('gift and trial use server variant, never the amount alone', () {
    expect(
        parse({
          'trialSecondsLeft': 604000,
          'trialExperimentVariant': 'referral_168h'
        }).kindAt(start),
        ProfileAccessKind.gift);
    expect(
        parse({
          'trialSecondsLeft': 604000,
          'trialExperimentVariant': 'variant_72h'
        }).kindAt(start),
        ProfileAccessKind.trial);
  });
  test('paid access has priority over remaining trial and queued bonus', () {
    final value = parse({
      'trialSecondsLeft': 100,
      'trialExperimentVariant': 'referral_168h',
      'hasActiveSubscription': true,
      'subscription_source': 'wata_sbp',
      'subscription_expires_at': '2026-11-05T09:00:00Z',
      'bonus_seconds': 259200
    });
    expect(value.kindAt(start), ProfileAccessKind.paid);
    expect(value.bonusSeconds, 259200);
    expect(value.autoRenew, isFalse);
  });
  test('expiry stays absolute through a later menu open and cache restore', () {
    final value =
        parse({'trialSecondsLeft': 60, 'hasActiveSubscription': false});
    final restored =
        ProfileAccessSnapshot.fromJson(jsonDecode(jsonEncode(value.toJson())));
    expect(restored.expiresAt(start.add(const Duration(seconds: 30))),
        start.add(const Duration(seconds: 60)));
    expect(restored.kindAt(start.add(const Duration(seconds: 60))),
        ProfileAccessKind.ended);
  });
  test('UTC and offset suffixes agree with naive backend UTC', () {
    expect(ProfileAccessSnapshot.serverDate('2026-10-05T12:00:00'),
        ProfileAccessSnapshot.serverDate('2026-10-05T15:00:00+03:00'));
    expect(ProfileAccessSnapshot.serverDate('invalid'), isNull);
  });
  test('missing status is unknown rather than a fabricated trial/date', () {
    final value = parse({});
    expect(value.kindAt(start), ProfileAccessKind.unknown);
    expect(value.expiresAt(start), isNull);
  });
  test('explicit inactive status and expired paid status do not show active',
      () {
    expect(
        parse({'trialSecondsLeft': 0, 'hasActiveSubscription': false})
            .kindAt(start),
        ProfileAccessKind.ended);
    expect(
        parse({
          'hasActiveSubscription': true,
          'subscription_expires_at': '2026-10-04T09:00:00Z'
        }).kindAt(start),
        ProfileAccessKind.ended);
  });
}

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../lib/models/profile_access_snapshot.dart';
import '../lib/services/auth_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // These are platform-independent cache tests; Firebase is not initialized by
  // this harness. Native/Firebase wiring is covered by separate contract suites.
  setUpAll(() => debugDefaultTargetPlatformOverride = TargetPlatform.linux);
  tearDownAll(() => debugDefaultTargetPlatformOverride = null);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
      'display snapshot persists and restores without altering bonus authorization',
      () async {
    final auth = AuthService();
    await auth.waitForTokenLoad();
    await auth.applyUserStatusSnapshot({
      'hasActiveSubscription': true,
      'trialSecondsLeft': 0,
      'subscription_source': 'referral_bonus',
      'subscription_auto_renew': false,
      'subscription_expires_at': '2099-10-08T12:59:13Z',
      'bonus_seconds': 259200,
    });
    expect(auth.hasActiveSubscription,
        isTrue); // Keep the existing backend contract.
    expect(auth.subscriptionSource, 'referral_bonus');
    expect(auth.profileAccessSnapshot.kindAt(DateTime.now()),
        ProfileAccessKind.bonus);
    final prefs = await SharedPreferences.getInstance();
    final stored =
        jsonDecode(prefs.getString('profile_access_snapshot_v1')!) as Map;
    expect(stored['source'], 'referral_bonus');
    final restored = AuthService();
    await restored.waitForTokenLoad();
    expect(restored.profileAccessSnapshot.subscriptionExpiresAt,
        auth.profileAccessSnapshot.subscriptionExpiresAt);
    expect(restored.profileAccessSnapshot.kindAt(DateTime.now()),
        ProfileAccessKind.bonus);
    await auth.logout();
    expect(prefs.containsKey('profile_access_snapshot_v1'), isFalse);
    expect(auth.profileAccessSnapshot.kindAt(DateTime.now()),
        ProfileAccessKind.unknown);
    auth.dispose();
    restored.dispose();
  });
  test('persisted trial deadline remains fixed across process restart',
      () async {
    final auth = AuthService();
    await auth.waitForTokenLoad();
    await auth.applyUserStatusSnapshot({
      'hasActiveSubscription': false,
      'trialSecondsLeft': 600,
      'trialExperimentVariant': 'referral_168h'
    });
    final expiry = auth.profileAccessSnapshot.trialExpiresAt;
    final restored = AuthService();
    await restored.waitForTokenLoad();
    expect(restored.profileAccessSnapshot.trialExpiresAt, expiry);
    expect(restored.profileAccessSnapshot.kindAt(DateTime.now()),
        ProfileAccessKind.gift);
    expect(restored.trialSecondsLeft,
        600); // The UI cache never decrements the entitlement field.
    auth.dispose();
    restored.dispose();
  });
  test('legacy unanchored trial cache has no invented expiry', () async {
    SharedPreferences.setMockInitialValues({'trial_seconds_left': 600});
    final auth = AuthService();
    await auth.waitForTokenLoad();
    expect(auth.trialSecondsLeft, 600);
    expect(auth.profileAccessSnapshot.trialExpiresAt, isNull);
    expect(auth.profileAccessSnapshot.kindAt(DateTime.now()),
        ProfileAccessKind.unknown);
    auth.dispose();
  });
}

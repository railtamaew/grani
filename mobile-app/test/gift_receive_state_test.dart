import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/models/gift_receive_state.dart';
import 'package:mobile_app/services/gift_presentation_policy.dart';
import 'package:mobile_app/core/storage/shared_preferences_holder.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final at = DateTime.utc(2026, 10, 5);
  final eligible = {'eligible': true, 'claim_before': '2026-10-06T00:00:00Z'};
  test('no invitation does not imply a gift was received', () {
    expect(
      giftReceiveState(
        authenticated: true,
        hasInvitation: false,
        eligibility: eligible,
        now: at,
      ),
      GiftReceiveState.enterCode,
    );
    expect(
      giftReceiveState(
        authenticated: false,
        hasInvitation: true,
        offer: {'available': true},
        now: at,
      ),
      GiftReceiveState.signIn,
    );
  });
  test('own code and account eligibility are independent', () {
    expect(
      giftReceiveState(
        authenticated: true,
        hasInvitation: false,
        eligibility: {'eligible': false},
        notice: 'self_referral',
        now: at,
      ),
      GiftReceiveState.ownInvitation,
    );
    expect(canEnterAnotherGiftCode({'eligible': false}, now: at), false);
    expect(canEnterAnotherGiftCode(eligible, now: at), true);
  });
  test('another code cannot repair expired or ineligible account', () {
    expect(
      giftReceiveState(
        authenticated: true,
        hasInvitation: false,
        eligibility: {'eligible': false, 'reason': 'existing_customer'},
        notice: 'invalid_code',
        now: at,
      ),
      GiftReceiveState.accountUnavailable,
    );
    final expired = {'eligible': true, 'claim_before': '2026-10-05T00:00:00Z'};
    expect(
      giftReceiveState(
        authenticated: true,
        hasInvitation: false,
        eligibility: expired,
        now: at,
      ),
      GiftReceiveState.accountUnavailable,
    );
    expect(canEnterAnotherGiftCode(expired, now: at), false);
  });
  test('unavailable code and unavailable account are not interchangeable', () {
    expect(
      giftReceiveState(
        authenticated: false,
        hasInvitation: true,
        offer: {'available': false, 'reason': 'invitation_unavailable'},
        now: at,
      ),
      GiftReceiveState.invalidInvitation,
    );
    expect(
      giftReceiveState(
        authenticated: true,
        hasInvitation: true,
        eligibility: eligible,
        notice: 'network_error',
        now: at,
      ),
      GiftReceiveState.retry,
    );
  });
  test('missing account facts never invite blind activation', () {
    expect(
      giftReceiveState(authenticated: true, hasInvitation: false),
      GiftReceiveState.retry,
    );
    expect(
      giftReceiveState(
        authenticated: true,
        hasInvitation: false,
        notice: 'existing_customer',
      ),
      GiftReceiveState.accountUnavailable,
    );
    expect(
      giftReceiveState(
        authenticated: true,
        hasInvitation: false,
        offer: {'unavailable_reason': 'campaign_unavailable'},
      ),
      GiftReceiveState.campaignUnavailable,
    );
  });
  test('receipt controls expiry and is not another activation form', () {
    final gift = {'trial_expires_at': '2026-10-06T00:00:00Z'};
    expect(
      giftReceiveState(
        authenticated: true,
        hasInvitation: false,
        received: gift,
        eligibility: {'eligible': false},
        now: at,
      ),
      GiftReceiveState.activated,
    );
    expect(
      giftReceiveState(
        authenticated: true,
        hasInvitation: false,
        received: gift,
        now: DateTime.utc(2026, 10, 6),
      ),
      GiftReceiveState.ended,
    );
  });
  test('activation stays in journal; sender reward has one presentation', () {
    expect(
      showGiftForegroundBanner({
        'event': 'referral_gift_received',
      }, alreadyInJournal: false),
      false,
    );
    expect(
      showGiftForegroundBanner({
        'event': 'referral_reward_granted',
      }, alreadyInJournal: false),
      true,
    );
    expect(
      showGiftForegroundBanner({
        'event': 'referral_reward_granted',
      }, alreadyInJournal: true),
      false,
    );
  });
  test(
    'celebration survives reopen and is scoped to account and receipt',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      await (await getSharedPreferences()).clear();
      final receipt = {'trial_expires_at': '2030-01-01T00:00:00Z'};
      expect(await consumeGiftCelebration('1', receipt), true);
      expect(await consumeGiftCelebration('1', receipt), false);
      expect(await consumeGiftCelebration('2', receipt), true);
      expect(
        await Future.wait([
          consumeGiftCelebration('3', receipt),
          consumeGiftCelebration('3', receipt),
        ]),
        [true, false],
      );
    },
  );
}

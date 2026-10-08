enum GiftReceiveState {
  enterCode,
  signIn,
  ownInvitation,
  invalidInvitation,
  accountUnavailable,
  campaignUnavailable,
  retry,
  activated,
  ended,
}

/// Choose one screen from server facts. A code failure is not an account ban.
GiftReceiveState giftReceiveState({
  required bool authenticated,
  required bool hasInvitation,
  Map? eligibility,
  Map? received,
  Map? offer,
  String? notice,
  bool requestFailed = false,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  if (notice == 'self_referral') return GiftReceiveState.ownInvitation;
  if (authenticated && received != null) {
    final end = DateTime.tryParse(
      received['trial_expires_at']?.toString() ?? '',
    );
    return end != null && !end.isAfter(at)
        ? GiftReceiveState.ended
        : GiftReceiveState.activated;
  }
  if (requestFailed) return GiftReceiveState.retry;
  final before = DateTime.tryParse(
    eligibility?['claim_before']?.toString() ?? '',
  );
  if (authenticated &&
      (eligibility?['eligible'] == false ||
          before != null && !before.isAfter(at) ||
          const {
            'claim_window_expired',
            'existing_customer',
            'device_already_used',
            'already_claimed',
          }.contains(notice))) {
    return GiftReceiveState.accountUnavailable;
  }
  if (notice == 'network_error' || notice == 'unavailable') {
    return GiftReceiveState.retry;
  }
  if (notice == 'campaign_unavailable' ||
      notice == 'campaign_limit' ||
      offer?['reason'] == 'campaign_unavailable' ||
      offer?['unavailable_reason'] == 'campaign_unavailable') {
    return GiftReceiveState.campaignUnavailable;
  }
  if (notice == 'invalid_code' ||
      hasInvitation && offer?['available'] == false) {
    return GiftReceiveState.invalidInvitation;
  }
  if (authenticated && eligibility == null) return GiftReceiveState.retry;
  if (hasInvitation) return GiftReceiveState.signIn;
  return GiftReceiveState.enterCode;
}

bool canEnterAnotherGiftCode(Map? eligibility, {DateTime? now}) {
  if (eligibility?['eligible'] != true) return false;
  final before = DateTime.tryParse(
    eligibility?['claim_before']?.toString() ?? '',
  );
  return before == null || before.isAfter(now ?? DateTime.now());
}

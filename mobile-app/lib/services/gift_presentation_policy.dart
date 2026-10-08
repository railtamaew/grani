import '../core/storage/shared_preferences_holder.dart';

/// Activation is presented by the result screen and retained in the journal.
/// Sender rewards may have one foreground banner, never two simultaneous alerts.
bool isGiftNotification(Map<String, dynamic> data) =>
    data['event'] == 'referral_gift_received' ||
    data['event'] == 'referral_reward_granted';

bool showGiftForegroundBanner(
  Map<String, dynamic> data, {
  required bool alreadyInJournal,
}) => data['event'] == 'referral_reward_granted' && !alreadyInJournal;

final _celebrationsInFlight = <String>{};

Future<bool> consumeGiftCelebration(String account, Map received) async {
  final expiry = received['trial_expires_at']?.toString();
  if (expiry == null || DateTime.tryParse(expiry) == null) return false;
  final key = 'grani_gift_celebration_v3_${account}_$expiry';
  if (!_celebrationsInFlight.add(key)) return false;
  try {
    final prefs = await getSharedPreferences();
    if (prefs.getBool(key) == true) return false;
    return await prefs.setBool(key, true);
  } finally {
    _celebrationsInFlight.remove(key);
  }
}

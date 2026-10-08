import '../../models/profile_access_snapshot.dart';
import '../grani_avatar.dart';

/// Cosmetic presentation from confirmed server history; never an entitlement.
GraniAvatarType? accessAvatarType(ProfileAccessSnapshot access, DateTime now) {
  final seconds = access.paidElapsedSeconds;
  if (seconds != null && seconds > 0) {
    if (seconds >= 365 * 86400) return GraniAvatarType.legend;
    if (seconds >= 180 * 86400) return GraniAvatarType.master;
    if (seconds >= 90 * 86400) return GraniAvatarType.keeper;
    if (seconds >= 30 * 86400) return GraniAvatarType.navigator;
    return GraniAvatarType.guide;
  }
  const paidSources = {
    'google_play',
    'google_play_extension',
    'wata_sbp',
    'cloudpayments',
  };
  if (access.kindAt(now) == ProfileAccessKind.paid &&
      paidSources.contains(access.source)) {
    return GraniAvatarType.guide;
  }
  if (seconds == 0 && access.known) return GraniAvatarType.iskra;
  // Missing history is not proof that an existing account is new.
  return null;
}

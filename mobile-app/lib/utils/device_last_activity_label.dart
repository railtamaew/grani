import '../l10n/app_localizations.dart';

/// Подпись «давности» для карточки устройства (список / лимит).
String deviceLastActivityLabel(
  Map<String, dynamic> d,
  AppLocalizations l10n, {
  String? whenNoTimestamp,
}) {
  final lastSeen = d['last_seen'] ??
      d['last_activity'] ??
      d['last_connected'] ??
      d['updated_at'];
  if (lastSeen == null) return whenNoTimestamp ?? '';

  DateTime? dt;
  if (lastSeen is int) {
    dt = DateTime.fromMillisecondsSinceEpoch(lastSeen);
  } else if (lastSeen is String) {
    dt = DateTime.tryParse(lastSeen);
  }
  if (dt == null) return whenNoTimestamp ?? '';

  final diff = DateTime.now().difference(dt);
  if (diff.inDays >= 30) return l10n.deviceLastSeenMonthAgo;
  if (diff.inDays >= 7) return l10n.deviceLastSeenWeekAgo;
  if (diff.inDays >= 1) return l10n.deviceLastSeenYesterday;
  if (diff.inHours >= 1) {
    return l10n.deviceLastSeenHoursAgo(diff.inHours.toString());
  }
  if (diff.inMinutes >= 1) {
    return l10n.deviceLastSeenMinutesAgo(diff.inMinutes.toString());
  }
  return l10n.deviceLastSeenJustNow;
}

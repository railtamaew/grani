/// Display-only snapshot. It never grants access or chooses a payment provider.
enum ProfileAccessKind { paid, trial, gift, bonus, ended, unknown }

class ProfileAccessSnapshot {
  const ProfileAccessSnapshot({
    required this.capturedAt,
    this.known = false,
    this.active = false,
    this.source,
    this.trialVariant,
    this.trialExpiresAt,
    this.subscriptionExpiresAt,
    this.autoRenew = false,
    this.bonusSeconds = 0,
    this.bonusStartsAt,
    this.bonusExpiresAt,
    this.trialTotalSeconds = 0,
    this.subscriptionStartedAt,
    this.paidElapsedSeconds,
    this.accountKey,
  });

  final DateTime capturedAt;
  final bool known, active, autoRenew;
  final String? source, trialVariant;
  final DateTime? trialExpiresAt, subscriptionExpiresAt;
  final int bonusSeconds;
  final DateTime? bonusStartsAt, bonusExpiresAt;
  final int trialTotalSeconds;
  final DateTime? subscriptionStartedAt;
  final int? paidElapsedSeconds;
  final String? accountKey;

  /// A tenure month is 30 elapsed days of recorded paid coverage.
  int? get paidMonths =>
      paidElapsedSeconds == null ? null : paidElapsedSeconds! ~/ (30 * 86400);
  int get avatarTier {
    final months = paidMonths ?? 0;
    if (months >= 12) return 4;
    if (months >= 6) return 3;
    if (months >= 3) return 2;
    if (months >= 1) return 1;
    return 0;
  }

  // Backend datetime.utcnow().isoformat() has no suffix; these values are UTC.
  static DateTime? serverDate(dynamic value) {
    if (value is! String || value.isEmpty) return null;
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return null;
    if (RegExp(r'(Z|[+-]\d\d:?\d\d)$', caseSensitive: false).hasMatch(value)) {
      return parsed.toUtc();
    }
    return DateTime.utc(parsed.year, parsed.month, parsed.day, parsed.hour,
        parsed.minute, parsed.second, parsed.millisecond, parsed.microsecond);
  }

  static int _seconds(dynamic value) =>
      value is num ? value.toInt().clamp(0, 2147483647) : 0;

  factory ProfileAccessSnapshot.fromPayload(Map<String, dynamic> data,
      {required DateTime now,
      String? accountKey,
      ProfileAccessSnapshot? previous}) {
    final remaining =
        _seconds(data['trialSecondsLeft'] ?? data['trial_seconds_left']);
    return ProfileAccessSnapshot(
      capturedAt: now.toUtc(),
      accountKey: accountKey,
      known: data.containsKey('trialSecondsLeft') ||
          data.containsKey('trial_seconds_left') ||
          data.containsKey('hasActiveSubscription') ||
          data.containsKey('has_active_subscription'),
      active:
          (data['hasActiveSubscription'] ?? data['has_active_subscription']) ==
              true,
      source: data['subscription_source'] as String?,
      trialVariant: (data['trialExperimentVariant'] ??
          data['trial_experiment_variant']) as String?,
      trialExpiresAt:
          remaining > 0 ? now.toUtc().add(Duration(seconds: remaining)) : null,
      subscriptionExpiresAt: serverDate(data['subscription_expires_at']),
      autoRenew: data['subscription_auto_renew'] == true,
      bonusSeconds: _seconds(data['bonus_seconds']),
      bonusStartsAt: serverDate(data['bonus_starts_at']),
      bonusExpiresAt: serverDate(data['bonus_expires_at']),
      trialTotalSeconds:
          _seconds(data['trialTotalSeconds'] ?? data['trial_total_seconds']),
      subscriptionStartedAt: serverDate(data['subscription_started_at']),
      paidElapsedSeconds: data['paid_access_elapsed_seconds'] is num
          ? _seconds(data['paid_access_elapsed_seconds'])
          : accountKey != null && previous?.accountKey == accountKey
              ? previous?.paidElapsedSeconds
              : null,
    );
  }

  ProfileAccessKind kindAt(DateTime now) {
    if (!known) return ProfileAccessKind.unknown;
    if (active &&
        (subscriptionExpiresAt == null ||
            subscriptionExpiresAt!.isAfter(now))) {
      return source == 'referral_bonus'
          ? ProfileAccessKind.bonus
          : ProfileAccessKind.paid;
    }
    if (trialExpiresAt != null && trialExpiresAt!.isAfter(now)) {
      return trialVariant == 'referral_168h'
          ? ProfileAccessKind.gift
          : ProfileAccessKind.trial;
    }
    return ProfileAccessKind.ended;
  }

  DateTime? expiresAt(DateTime now) => switch (kindAt(now)) {
        ProfileAccessKind.paid ||
        ProfileAccessKind.bonus =>
          subscriptionExpiresAt,
        ProfileAccessKind.trial || ProfileAccessKind.gift => trialExpiresAt,
        _ => null,
      };

  double? remainingFractionAt(DateTime now) {
    final end = expiresAt(now);
    if (end == null) return null;
    final kind = kindAt(now);
    final total = switch (kind) {
      ProfileAccessKind.trial || ProfileAccessKind.gift => trialTotalSeconds,
      ProfileAccessKind.paid => subscriptionStartedAt == null
          ? 0
          : end.difference(subscriptionStartedAt!).inSeconds,
      ProfileAccessKind.bonus =>
        bonusStartsAt == null ? 0 : end.difference(bonusStartsAt!).inSeconds,
      _ => 0,
    };
    if (total <= 0) return null;
    return (end.difference(now).inSeconds / total).clamp(0.0, 1.0);
  }

  /// Persist only display fields, with absolute expiry. Reopening cannot add time.
  Map<String, dynamic> toJson() => {
        'captured_at': capturedAt.toIso8601String(),
        'known': known,
        'active': active,
        'source': source,
        'trial_variant': trialVariant,
        'auto_renew': autoRenew,
        'trial_expires_at': trialExpiresAt?.toIso8601String(),
        'subscription_expires_at': subscriptionExpiresAt?.toIso8601String(),
        'bonus_seconds': bonusSeconds,
        'bonus_starts_at': bonusStartsAt?.toIso8601String(),
        'bonus_expires_at': bonusExpiresAt?.toIso8601String(),
        'trial_total_seconds': trialTotalSeconds,
        'subscription_started_at': subscriptionStartedAt?.toIso8601String(),
        'paid_access_elapsed_seconds': paidElapsedSeconds,
        'account_key': accountKey,
      };

  factory ProfileAccessSnapshot.fromJson(Map<String, dynamic> data) =>
      ProfileAccessSnapshot(
        accountKey: data['account_key'] is String
            ? data['account_key'] as String
            : null,
        capturedAt: serverDate(data['captured_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        known: data['known'] == true,
        active: data['active'] == true,
        source: data['source'] as String?,
        trialVariant: data['trial_variant'] as String?,
        autoRenew: data['auto_renew'] == true,
        trialExpiresAt: serverDate(data['trial_expires_at']),
        subscriptionExpiresAt: serverDate(data['subscription_expires_at']),
        bonusSeconds: _seconds(data['bonus_seconds']),
        bonusStartsAt: serverDate(data['bonus_starts_at']),
        bonusExpiresAt: serverDate(data['bonus_expires_at']),
        trialTotalSeconds: _seconds(data['trial_total_seconds']),
        subscriptionStartedAt: serverDate(data['subscription_started_at']),
        paidElapsedSeconds: data['paid_access_elapsed_seconds'] is num
            ? _seconds(data['paid_access_elapsed_seconds'])
            : null,
      );
}

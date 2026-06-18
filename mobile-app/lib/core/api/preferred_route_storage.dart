import 'package:flutter/foundation.dart';
import 'dart:convert';

import '../../config/app_config.dart';
import '../storage/shared_preferences_holder.dart';

/// Хранит маршрут API, который последний раз успешно ответил.
/// Используется для приоритизации при следующих запросах и для логирования на бэкенде.
class PreferredRouteStorage {
  PreferredRouteStorage._();

  static const _key = 'grani_preferred_api_base_url';
  static const _keySavedAt = 'grani_preferred_api_base_url_saved_at';
  static const _keyRouteHealth = 'grani_route_health_v1';
  static const _keyRecentNetClass = 'grani_recent_net_class_fail_v1';

  /// Окно «cooldown» для [EndpointRouter] vpnControl: только network-class ошибки, не HTTP 4xx от живого сервера.
  /// См. [recordNetworkClassFailure] / [ApiClient].
  static const Duration recentNetworkClassTtl = Duration(seconds: 30);
  static const _ttlHours = 24;
  static const _criticalFailureThreshold = 2;
  static const _nonCriticalFailureThreshold = 4;
  static const _criticalCooldownMinutes = 10;
  static const _nonCriticalCooldownMinutes = 5;
  static const _decayStepMinutes = 5;

  static void _logRouteVerbose(String message) {
    if (AppConfig.enableRouteVerboseLogs) {
      debugPrint(message);
    }
  }

  /// Последний успешный маршрут в текущей сессии (для api_route_used в логах).
  static String? _lastSuccessfulRouteForLogging;

  /// Сохранить успешный маршрут (для следующих сессий и для логирования).
  static Future<void> saveSuccessfulRoute(String baseUrl) async {
    if (baseUrl.isEmpty) return;
    _lastSuccessfulRouteForLogging = baseUrl;
    try {
      final prefs = await getSharedPreferences();
      await prefs.setString(_key, baseUrl);
      await prefs.setInt(_keySavedAt, DateTime.now().millisecondsSinceEpoch);
      await _clearRouteFailure(baseUrl, prefs: prefs);
      await clearRecentNetworkClassFailure(baseUrl, prefs: prefs);
    } catch (e) {
      debugPrint('PreferredRouteStorage.saveSuccessfulRoute: $e');
    }
  }

  /// Пометить маршрут как временно проблемный (retryable таймаут/сеть).
  static Future<void> reportRouteFailure(String baseUrl, {String? path}) async {
    if (baseUrl.isEmpty) return;
    try {
      final prefs = await getSharedPreferences();
      final map = await _readHealthMap(prefs: prefs);
      final now = DateTime.now().millisecondsSinceEpoch;
      final policy = path != null ? routePolicyForPath(path) : 'domain_first';
      final raw = _normalizeEntry(map[baseUrl], now);
      final failCount = ((raw?['failCount'] as int?) ?? 0) + 1;
      final next = <String, dynamic>{
        'failCount': failCount,
        'lastFailureAt': now,
        'policy': policy,
      };
      if (failCount >= _failureThresholdForPolicy(policy)) {
        next['cooldownUntil'] = now +
            Duration(minutes: _cooldownMinutesForPolicy(policy)).inMilliseconds;
      }
      _logRouteVerbose(
        'PreferredRouteStorage: route_failure base=$baseUrl policy=$policy failCount=$failCount cooldownUntil=${next['cooldownUntil'] ?? 0}',
      );
      map[baseUrl] = next;
      await prefs.setString(_keyRouteHealth, jsonEncode(map));
    } catch (e) {
      debugPrint('PreferredRouteStorage.reportRouteFailure: $e');
    }
  }

  static String _normalizeBaseKey(String baseUrl) {
    var s = baseUrl.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// Фиксирует network-class сбой по базе (для [EndpointRouter] vpnControl: второй origin в течение [recentNetworkClassTtl]).
  static Future<void> recordNetworkClassFailure(String baseUrl) async {
    if (baseUrl.isEmpty) return;
    try {
      final prefs = await getSharedPreferences();
      final map = await _readRecentNetMap(prefs: prefs);
      map[_normalizeBaseKey(baseUrl)] =
          DateTime.now().millisecondsSinceEpoch.toString();
      await prefs.setString(_keyRecentNetClass, jsonEncode(map));
    } catch (e) {
      debugPrint('PreferredRouteStorage.recordNetworkClassFailure: $e');
    }
  }

  static Future<void> clearRecentNetworkClassFailure(
    String baseUrl, {
    dynamic prefs,
  }) async {
    if (baseUrl.isEmpty) return;
    try {
      final p = prefs ?? await getSharedPreferences();
      final map = await _readRecentNetMap(prefs: p);
      if (map.remove(_normalizeBaseKey(baseUrl)) != null) {
        await p.setString(_keyRecentNetClass, jsonEncode(map));
      }
    } catch (e) {
      debugPrint('PreferredRouteStorage.clearRecentNetworkClassFailure: $e');
    }
  }

  /// Был ли недавний (&lt; [recentNetworkClassTtl]) network-class сбой для этой базы.
  static Future<bool> hasRecentNetworkClassFailure(String baseUrl) async {
    if (baseUrl.isEmpty) return false;
    try {
      final prefs = await getSharedPreferences();
      final map = await _readRecentNetMap(prefs: prefs);
      final key = _normalizeBaseKey(baseUrl);
      final raw = map[key];
      if (raw == null) return false;
      final at = int.tryParse(raw.toString());
      if (at == null) {
        map.remove(key);
        await prefs.setString(_keyRecentNetClass, jsonEncode(map));
        return false;
      }
      final age = DateTime.now().millisecondsSinceEpoch - at;
      if (age > recentNetworkClassTtl.inMilliseconds) {
        map.remove(key);
        await prefs.setString(_keyRecentNetClass, jsonEncode(map));
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('PreferredRouteStorage.hasRecentNetworkClassFailure: $e');
      return false;
    }
  }

  static Future<Map<String, dynamic>> _readRecentNetMap({dynamic prefs}) async {
    try {
      final p = prefs ?? await getSharedPreferences();
      final raw = p.getString(_keyRecentNetClass);
      if (raw == null || raw.isEmpty) return <String, dynamic>{};
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
      return <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// Получить сохранённый маршрут (если он ещё валиден по TTL).
  static Future<String?> getPreferredRoute() async {
    try {
      final prefs = await getSharedPreferences();
      final url = prefs.getString(_key);
      if (url == null || url.isEmpty) return null;
      final savedAt = prefs.getInt(_keySavedAt);
      if (savedAt == null) return url;
      final age = DateTime.now().millisecondsSinceEpoch - savedAt;
      if (age > _ttlHours * 3600 * 1000) {
        await clear();
        return null;
      }
      return url;
    } catch (e) {
      debugPrint('PreferredRouteStorage.getPreferredRoute: $e');
      return null;
    }
  }

  /// Последний успешный маршрут в текущей сессии (для передачи в логи).
  static String? get lastSuccessfulRouteForLogging =>
      _lastSuccessfulRouteForLogging;

  /// Сбросить сохранённый маршрут (при таймауте на preferred).
  static Future<void> clear() async {
    try {
      final prefs = await getSharedPreferences();
      await prefs.remove(_key);
      await prefs.remove(_keySavedAt);
    } catch (e) {
      debugPrint('PreferredRouteStorage.clear: $e');
    }
  }

  /// Порядок для перебора API-баз на мобильной сети без сохранённого preferred.
  /// Сначала доменный granilink ingress, direct IP/SNI — как последний fallback.
  /// `apiVpnServerUrl8443` (45.12.132.94:8444) держим в конце: на части сетей он медленнее домена.
  static List<String> prioritizeDomainRoutes(List<String> urls) {
    final hu8444 = AppConfig.apiVpnServerUrl8443;
    final fallbacksNo8444 =
        AppConfig.apiBaseUrlFallbacks.where((u) => u != hu8444).toList();
    final preferredDomains = <String>[
      AppConfig.apiBaseUrl,
      ...fallbacksNo8444,
      AppConfig.apiVpnServerUrl,
    ];
    final ordered = <String>[];
    for (final u in preferredDomains) {
      if (urls.contains(u) && !ordered.contains(u)) ordered.add(u);
    }
    for (final u in urls) {
      if (!ordered.contains(u) &&
          u != AppConfig.apiDirectIpUrl &&
          u != hu8444) {
        ordered.add(u);
      }
    }
    if (urls.contains(AppConfig.apiDirectIpUrl) &&
        !ordered.contains(AppConfig.apiDirectIpUrl)) {
      ordered.add(AppConfig.apiDirectIpUrl);
    }
    if (urls.contains(hu8444) && !ordered.contains(hu8444)) {
      ordered.add(hu8444);
    }
    return ordered;
  }

  static bool isCriticalControlPath(String path) {
    final p = path.trim().toLowerCase();
    return p == '/vpn/bootstrap' ||
        p == '/vpn/status' ||
        p == '/auth/me' ||
        p == '/vpn/device/resolve' ||
        p == '/vpn/device/register';
  }

  static String routePolicyForPath(String path) {
    return isCriticalControlPath(path)
        ? 'critical_direct_first'
        : 'domain_first';
  }

  /// Одноразово сбрасывает сохранённый preferred после смены политики «домен первым».
  static Future<void> applyDomainFirstPolicyMigration() async {
    const k = 'grani_domain_first_policy_v1';
    try {
      final prefs = await getSharedPreferences();
      if (prefs.getBool(k) == true) return;
      await clear();
      await prefs.setBool(k, true);
    } catch (e) {
      debugPrint('PreferredRouteStorage.applyDomainFirstPolicyMigration: $e');
    }
  }

  static Future<Map<String, dynamic>> _readHealthMap({
    dynamic prefs,
  }) async {
    try {
      final p = prefs ?? await getSharedPreferences();
      final raw = p.getString(_keyRouteHealth);
      if (raw == null || raw.isEmpty) return <String, dynamic>{};
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static Future<void> _clearRouteFailure(
    String baseUrl, {
    dynamic prefs,
  }) async {
    final p = prefs ?? await getSharedPreferences();
    final map = await _readHealthMap(prefs: p);
    if (map.remove(baseUrl) != null) {
      await p.setString(_keyRouteHealth, jsonEncode(map));
    }
  }

  static int _failureThresholdForPolicy(String policy) {
    return policy == 'critical_direct_first'
        ? _criticalFailureThreshold
        : _nonCriticalFailureThreshold;
  }

  static int _cooldownMinutesForPolicy(String policy) {
    return policy == 'critical_direct_first'
        ? _criticalCooldownMinutes
        : _nonCriticalCooldownMinutes;
  }

  static Map<String, dynamic>? _normalizeEntry(dynamic raw, int now) {
    if (raw is! Map) return null;
    final lastFailureAt = raw['lastFailureAt'] as int?;
    var failCount = (raw['failCount'] as int?) ?? 0;
    final policy = (raw['policy'] as String?) ?? 'domain_first';
    if (lastFailureAt != null && failCount > 0) {
      final elapsedMs = now - lastFailureAt;
      if (elapsedMs > 0) {
        final elapsedSteps =
            elapsedMs ~/ Duration(minutes: _decayStepMinutes).inMilliseconds;
        if (elapsedSteps > 0) {
          failCount = (failCount - elapsedSteps).clamp(0, 1000).toInt();
        }
      }
    }
    final cooldownUntil = raw['cooldownUntil'] as int?;
    if (failCount <= 0 && (cooldownUntil == null || cooldownUntil <= now)) {
      return null;
    }
    final out = <String, dynamic>{
      'failCount': failCount,
      'lastFailureAt': lastFailureAt ?? now,
      'policy': policy,
    };
    if (cooldownUntil != null && cooldownUntil > now) {
      out['cooldownUntil'] = cooldownUntil;
    }
    return out;
  }
}

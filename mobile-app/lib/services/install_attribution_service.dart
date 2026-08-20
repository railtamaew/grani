import 'dart:async';
import 'dart:convert';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../core/logger/logger.dart';
import '../core/storage/shared_preferences_holder.dart';

/// First-party website attribution and verified App Link intake.
///
/// The payload is intentionally allow-listed: no full user agent, ad ID,
/// device model, email, or other personal identifier is stored.
class InstallAttributionService {
  InstallAttributionService._();

  static final InstallAttributionService instance =
      InstallAttributionService._();

  static const _channel = MethodChannel('com.granivpn.mobile/app_links');
  static const _referrerReadKey = 'grani_install_referrer_read_v1';
  static const _attributionKey = 'grani_install_attribution_v1';
  static const _pendingRouteKey = 'grani_pending_app_link_route_v1';
  static const _eventPrefix = 'grani_attribution_event_v1_';
  static const _claimPrefix = 'grani_install_attribution_claimed_v1_';
  static const _appLinksEnabled =
      bool.fromEnvironment('APP_LINKS_ENABLED', defaultValue: true);
  static const _installReferrerEnabled =
      bool.fromEnvironment('INSTALL_REFERRER_ENABLED', defaultValue: true);
  static const _allowedKeys = <String>{
    'gclid',
    'gbraid',
    'wbraid',
    'utm_source',
    'utm_medium',
    'utm_campaign',
    'utm_content',
    'utm_term',
    'landing',
    'locale',
    'variant',
    'campaign',
    'ad_group',
    'keyword_cluster',
    'attribution_id',
    'click_time',
  };
  static const _lifecycleAnalyticsKeys = <String>{
    'utm_source',
    'utm_medium',
    'utm_campaign',
    'attribution_id',
  };

  final _links = StreamController<String>.broadcast();
  final _logger = Logger();
  Map<String, String> _attribution = const {};
  bool _initialized = false;

  Stream<String> get links => _links.stream;

  Future<void> initialize() async {
    if (_initialized ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (!_appLinksEnabled) return;
      if (call.method == 'onAppLink' && call.arguments is String) {
        await _acceptAppLink(call.arguments as String);
      }
    });

    final prefs = await getSharedPreferences();
    final cached = prefs.getString(_attributionKey);
    if (cached != null) {
      try {
        _attribution = Map<String, String>.from(
          jsonDecode(cached) as Map<String, dynamic>,
        );
      } catch (_) {
        _attribution = const {};
      }
    }

    try {
      if (!_appLinksEnabled) throw const FormatException('App Links disabled');
      final initial = await _channel.invokeMethod<String>('getInitialLink');
      if (initial != null) await _acceptAppLink(initial);
    } catch (_) {}

    if (_installReferrerEnabled &&
        !(prefs.getBool(_referrerReadKey) ?? false)) {
      var referrerRead = false;
      try {
        final response = await _channel.invokeMapMethod<String, dynamic>(
          'getInstallReferrer',
        );
        if (response != null) {
          referrerRead = true;
          final raw = response['install_referrer']?.toString() ?? '';
          final parsed = Uri.splitQueryString(raw);
          final safe = _safeAttribution(parsed, base: _attribution);
          final clickTime = int.tryParse(
              response['click_timestamp_seconds']?.toString() ?? '');
          if (clickTime != null &&
              clickTime > 0 &&
              !safe.containsKey('click_time')) {
            safe['click_time'] = clickTime.toString();
          }
          if (safe.isNotEmpty) {
            _attribution = safe;
            await prefs.setString(_attributionKey, jsonEncode(safe));
          }
        }
      } catch (_) {
        // Best effort. The next cold start may retry if Play was unavailable.
      } finally {
        if (referrerRead) {
          await prefs.setBool(_referrerReadKey, true);
        }
      }
    }

    await _logCampaignDetails();
  }

  Future<void> _acceptAppLink(String raw) async {
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'granilink.com' ||
        (uri.path != '/open' && !uri.path.startsWith('/open/'))) {
      return;
    }
    final route = _mapPath(uri.path);
    final prefs = await getSharedPreferences();
    final safe = _safeAttribution(uri.queryParameters, base: _attribution);
    if (safe.isNotEmpty) {
      _attribution = safe;
      await prefs.setString(_attributionKey, jsonEncode(safe));
      await _logCampaignDetails();
    }
    await prefs.setString(_pendingRouteKey, route);
    _links.add(route);
  }

  Map<String, String> _safeAttribution(
    Map<String, String> source, {
    Map<String, String> base = const {},
  }) {
    final safe = <String, String>{...base};
    for (final entry in source.entries) {
      if (!_allowedKeys.contains(entry.key) || entry.value.isEmpty) continue;
      final limit = entry.key.endsWith('clid') ? 256 : 160;
      safe[entry.key] = entry.value.length > limit
          ? entry.value.substring(0, limit)
          : entry.value;
    }
    return safe;
  }

  @visibleForTesting
  static Map<String, Object> lifecycleAttributionParameters(
    Map<String, String> attribution,
  ) =>
      {
        for (final entry in attribution.entries)
          if (_lifecycleAnalyticsKeys.contains(entry.key))
            entry.key: entry.value,
        'has_gclid': attribution.containsKey('gclid') ? 1 : 0,
        'has_gbraid': attribution.containsKey('gbraid') ? 1 : 0,
        'has_wbraid': attribution.containsKey('wbraid') ? 1 : 0,
      };

  Map<String, Object> _analyticsParameters() =>
      lifecycleAttributionParameters(_attribution);

  Future<void> _logCampaignDetails() async {
    if (!_attribution.containsKey('utm_source') &&
        !_attribution.containsKey('utm_campaign')) {
      return;
    }
    final prefs = await getSharedPreferences();
    final rawCampaignScope = _attribution['attribution_id'] ??
        '${_attribution['utm_source'] ?? 'unknown'}_'
            '${_attribution['utm_campaign'] ?? 'unknown'}';
    final sanitizedCampaignScope =
        rawCampaignScope.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    final campaignScope = sanitizedCampaignScope.length > 80
        ? sanitizedCampaignScope.substring(0, 80)
        : sanitizedCampaignScope;
    final marker = '${_eventPrefix}campaign_details_$campaignScope';
    if (prefs.getBool(marker) ?? false) return;
    final parameters = <String, Object>{
      if (_attribution['utm_source'] case final source?) 'source': source,
      if (_attribution['utm_medium'] case final medium?) 'medium': medium,
      if (_attribution['utm_campaign'] case final campaign?)
        'campaign': campaign,
      if (_attribution['utm_term'] case final term?) 'term': term,
      if (_attribution['utm_content'] case final content?) 'content': content,
      if (_attribution['attribution_id'] case final attributionId?)
        'attribution_id': attributionId,
    };
    try {
      await FirebaseAnalytics.instance.logEvent(
        name: 'campaign_details',
        parameters: parameters,
      );
      await prefs.setBool(marker, true);
    } catch (error) {
      _logger.warning(
        'analytics campaign_details failed: $error',
        'InstallAttributionService',
      );
    }
  }

  String _mapPath(String path) {
    switch (path) {
      case '/open/settings/split-tunneling':
        return '/split-tunnel';
      case '/open/pay':
        return '/trial-ended';
      case '/open':
      case '/open/home':
      case '/open/connect':
        return '/main';
      default:
        return '/main';
    }
  }

  Future<String?> takePendingRouteIfAuthorized(bool authorized) async {
    if (!authorized) return null;
    final prefs = await getSharedPreferences();
    final route = prefs.getString(_pendingRouteKey);
    if (route != null) await prefs.remove(_pendingRouteKey);
    return route;
  }

  Future<void> logLifecycleEvent(
    String eventName, {
    Map<String, Object>? extra,
    bool once = true,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final prefs = await getSharedPreferences();
    final marker = '$_eventPrefix$eventName';
    if (once && (prefs.getBool(marker) ?? false)) return;
    final parameters = <String, Object>{
      ..._analyticsParameters(),
      if (extra != null) ...extra,
    };
    try {
      await FirebaseAnalytics.instance.logEvent(
        name: eventName,
        parameters: parameters.isEmpty ? null : parameters,
      );
      if (once) await prefs.setBool(marker, true);
    } catch (error) {
      _logger.warning(
        'analytics event $eventName failed: $error',
        'InstallAttributionService',
      );
    }
  }

  /// Performs at most one short, asynchronous claim after a successful login.
  ///
  /// It is called from the existing post-auth background work, never blocks
  /// navigation, and creates no timer, polling loop, or startup network request.
  Future<void> claimAfterLogin(String? token) async {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        token == null ||
        token.isEmpty) {
      return;
    }
    final attributionId = _attribution['attribution_id'];
    if (attributionId == null || attributionId.isEmpty) return;
    final prefs = await getSharedPreferences();
    final marker = '$_claimPrefix$attributionId';
    if (prefs.getBool(marker) ?? false) return;

    final payload = <String, String>{
      'attribution_id': attributionId,
      for (final key in const [
        'utm_source',
        'utm_medium',
        'utm_campaign',
        'utm_content',
        'utm_term',
        'campaign',
        'landing',
      ])
        if (_attribution[key] case final value?) key: value,
    };
    try {
      final response = await http
          .post(
            Uri.parse(
              '${AppConfig.apiBaseUrl}/analytics/attribution/claim',
            ),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 4));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        await prefs.setBool(marker, true);
      }
    } catch (_) {
      // Best effort: one attempt per completed login, never a background loop.
    }
  }
}

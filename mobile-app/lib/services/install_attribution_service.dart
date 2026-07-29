import 'dart:async';
import 'dart:convert';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
  static const _appLinksEnabled =
      bool.fromEnvironment('APP_LINKS_ENABLED', defaultValue: true);
  static const _installReferrerEnabled =
      bool.fromEnvironment('INSTALL_REFERRER_ENABLED', defaultValue: true);
  static const _allowedKeys = <String>{
    'utm_source',
    'utm_medium',
    'utm_campaign',
    'landing',
    'locale',
    'variant',
    'campaign',
    'ad_group',
    'keyword_cluster',
  };

  final _links = StreamController<String>.broadcast();
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
      try {
        final response = await _channel.invokeMapMethod<String, dynamic>(
          'getInstallReferrer',
        );
        final raw = response?['install_referrer']?.toString() ?? '';
        if (raw.isNotEmpty) {
          final parsed = Uri.splitQueryString(raw);
          final safe = <String, String>{};
          for (final entry in parsed.entries) {
            if (_allowedKeys.contains(entry.key) && entry.value.isNotEmpty) {
              safe[entry.key] = entry.value.length > 100
                  ? entry.value.substring(0, 100)
                  : entry.value;
            }
          }
          if (safe.isNotEmpty) {
            _attribution = safe;
            await prefs.setString(_attributionKey, jsonEncode(safe));
          }
        }
      } catch (_) {
        // Best effort. The next cold start may retry if Play was unavailable.
      } finally {
        await prefs.setBool(_referrerReadKey, true);
      }
    }

    await logLifecycleEvent('first_open', once: true);
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
    await prefs.setString(_pendingRouteKey, route);
    _links.add(route);
  }

  String _mapPath(String path) {
    switch (path) {
      case '/open/settings/split-tunneling':
        return '/split-tunnel';
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
      ..._attribution,
      if (extra != null) ...extra,
    };
    try {
      await FirebaseAnalytics.instance.logEvent(
        name: eventName,
        parameters: parameters.isEmpty ? null : parameters,
      );
      if (once) await prefs.setBool(marker, true);
    } catch (_) {}
  }
}

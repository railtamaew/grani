import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:package_info_plus/package_info_plus.dart';

import '../core/api/api_client.dart';
import '../core/api/endpoint_router.dart';
import '../core/logger/logger.dart';
import '../core/storage/storage_service.dart';
import '../core/storage/shared_preferences_holder.dart';

class WindowsAnalyticsTransport {
  WindowsAnalyticsTransport._();

  static final WindowsAnalyticsTransport instance =
      WindowsAnalyticsTransport._();

  static const _installationIdKey = 'windows_analytics_installation_id_v1';
  static const _outboxKey = 'windows_analytics_outbox_v1';
  static const _userScopeKey = 'windows_analytics_user_scope_v1';
  static const _lastBuildKey = 'windows_analytics_last_build_v1';
  static const _firstOpenKey = 'windows_analytics_first_open_v1';
  static const _maxOutboxSize = 100;

  final Logger _logger = Logger();
  final String _sessionId = _newUuid();
  bool _initialized = false;
  bool _flushInProgress = false;
  String _appVersion = 'unknown';
  String _buildNumber = '0';

  Future<void> initialize({String? userId}) async {
    if (!Platform.isWindows) return;
    if (userId != null && userId.trim().isNotEmpty) {
      await setUserId(userId);
    }
    if (_initialized) {
      await flush();
      return;
    }
    _initialized = true;

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      _appVersion = packageInfo.version;
      _buildNumber = packageInfo.buildNumber;
    } catch (error) {
      _logger.warning(
        'Windows analytics package info unavailable: $error',
        'WindowsAnalyticsTransport',
      );
    }

    final prefs = await getSharedPreferences();
    final previousBuild = prefs.getString(_lastBuildKey);
    final firstOpenSent = prefs.getBool(_firstOpenKey) ?? false;
    if (!firstOpenSent) {
      await logEvent('windows_first_open');
      await prefs.setBool(_firstOpenKey, true);
    } else if (previousBuild != null &&
        previousBuild.isNotEmpty &&
        previousBuild != _buildNumber) {
      await logEvent(
        'windows_app_update',
        params: {'source_surface': 'desktop_startup'},
      );
    }
    await prefs.setString(_lastBuildKey, _buildNumber);
    await logEvent(
      'windows_app_open',
      params: {'source_surface': 'desktop_startup'},
    );
  }

  Future<void> setUserId(String? userId) async {
    if (!Platform.isWindows) return;
    final prefs = await getSharedPreferences();
    final normalized = userId?.trim();
    final previous = prefs.getString(_userScopeKey);
    if (normalized == null || normalized.isEmpty) {
      await prefs.remove(_userScopeKey);
      await prefs.remove(_outboxKey);
      return;
    }
    if (previous != null && previous.isNotEmpty && previous != normalized) {
      await prefs.remove(_outboxKey);
    }
    await prefs.setString(_userScopeKey, normalized);
    await flush();
  }

  Future<void> logEvent(
    String eventName, {
    Map<String, Object?> params = const {},
  }) async {
    if (!Platform.isWindows) return;
    try {
      final prefs = await getSharedPreferences();
      final installationId = await _installationId(prefs);
      final outbox = _readOutbox(prefs);
      outbox.add({
        'event_id': _newUuid(),
        'event_name': eventName,
        'occurred_at': DateTime.now().toUtc().toIso8601String(),
        'installation_id': installationId,
        'analytics_session_id': _sessionId,
        'app_version': _appVersion,
        'build_number': _buildNumber,
        'params': {
          for (final entry in params.entries)
            if (entry.value != null) entry.key: entry.value,
        },
      });
      if (outbox.length > _maxOutboxSize) {
        outbox.removeRange(0, outbox.length - _maxOutboxSize);
      }
      await _writeOutbox(prefs, outbox);
      await flush();
    } catch (error) {
      _logger.warning(
        'Windows analytics queue error: $error',
        'WindowsAnalyticsTransport',
      );
    }
  }

  Future<void> flush() async {
    if (!Platform.isWindows || _flushInProgress) return;
    _flushInProgress = true;
    try {
      final prefs = await getSharedPreferences();
      final userScope = prefs.getString(_userScopeKey);
      if (userScope == null || userScope.isEmpty) return;

      final storage = StorageService();
      final deviceId = (await storage.getSecureString('device_id')) ??
          (await storage.getString('device_id'));
      if (deviceId == null || deviceId.trim().isEmpty) return;

      while (true) {
        final outbox = _readOutbox(prefs);
        if (outbox.isEmpty) return;
        final batch = outbox.take(10).map((event) {
          return {
            ...event,
            'device_id': deviceId.trim(),
          };
        }).toList(growable: false);
        final response = await ApiClient().post(
          '/analytics/events',
          data: {
            'platform': 'windows',
            'events': batch,
          },
          requestKind: RequestKind.logging,
        );
        final responseData = response.data;
        final accepted = response.statusCode != null &&
            response.statusCode! >= 200 &&
            response.statusCode! < 300 &&
            responseData is Map &&
            responseData['ok'] == true;
        if (!accepted) return;
        outbox.removeRange(0, batch.length);
        await _writeOutbox(prefs, outbox);
      }
    } catch (error) {
      _logger.warning(
        'Windows analytics delivery deferred: $error',
        'WindowsAnalyticsTransport',
      );
    } finally {
      _flushInProgress = false;
    }
  }

  static List<Map<String, dynamic>> _readOutbox(dynamic prefs) {
    final raw = prefs.getString(_outboxKey);
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> _writeOutbox(
    dynamic prefs,
    List<Map<String, dynamic>> outbox,
  ) =>
      prefs.setString(_outboxKey, jsonEncode(outbox));

  static Future<String> _installationId(dynamic prefs) async {
    final stored = prefs.getString(_installationIdKey);
    if (stored != null && stored.isNotEmpty) return stored;
    final created = _newUuid();
    await prefs.setString(_installationIdKey, created);
    return created;
  }

  static String _newUuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((value) => value.toRadixString(16).padLeft(2, '0'));
    final value = hex.join();
    return '${value.substring(0, 8)}-'
        '${value.substring(8, 12)}-'
        '${value.substring(12, 16)}-'
        '${value.substring(16, 20)}-'
        '${value.substring(20)}';
  }
}

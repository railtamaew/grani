import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:in_app_update/in_app_update.dart';

import '../config/app_config.dart';
import '../core/api/api_client.dart';
import '../core/cache/cache_service.dart';
import '../core/logger/logger.dart';

class AppUpdateService {
  AppUpdateService._();
  static final AppUpdateService instance = AppUpdateService._();

  static const String _lastCheckAtKey = 'app_update_last_check_at_ms_v1';
  static const Duration _defaultCheckInterval = Duration(hours: 12);

  bool _isChecking = false;

  Future<void> checkForPlayUpdate({
    required String trigger,
    bool force = false,
  }) async {
    if (!Platform.isAndroid) return;
    if (_isChecking) return;
    if (!force && !await _shouldCheck()) return;

    _isChecking = true;
    try {
      final policy = await _fetchPolicy();
      await _markChecked();

      if (!policy.updateRequired || policy.mode == AppUpdateMode.none) {
        return;
      }

      final updateInfo = await InAppUpdate.checkForUpdate();
      if (updateInfo.updateAvailability != UpdateAvailability.updateAvailable) {
        Logger().debug(
          'Google Play update unavailable trigger=$trigger mode=${policy.mode.name}',
          'AppUpdateService',
        );
        return;
      }

      if (policy.mode == AppUpdateMode.immediate &&
          updateInfo.immediateUpdateAllowed) {
        Logger().info(
          'Starting immediate Google Play update trigger=$trigger',
          'AppUpdateService',
        );
        await InAppUpdate.performImmediateUpdate();
        return;
      }

      if (updateInfo.flexibleUpdateAllowed) {
        Logger().info(
          'Starting flexible Google Play update trigger=$trigger',
          'AppUpdateService',
        );
        await InAppUpdate.startFlexibleUpdate();
        await InAppUpdate.completeFlexibleUpdate();
      }
    } catch (e) {
      Logger().debug(
        'In-app update check skipped trigger=$trigger error=$e',
        'AppUpdateService',
      );
    } finally {
      _isChecking = false;
    }
  }

  Future<bool> _shouldCheck() async {
    final last = await CacheService().getInt(_lastCheckAtKey);
    if (last == null || last <= 0) return true;
    final elapsed = DateTime.now().millisecondsSinceEpoch - last;
    return elapsed >= _defaultCheckInterval.inMilliseconds;
  }

  Future<void> _markChecked() async {
    await CacheService().setInt(
      _lastCheckAtKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<AppUpdatePolicy> _fetchPolicy() async {
    final versionCode = int.tryParse(AppConfig.buildNumber) ?? 0;
    final response = await ApiClient().get(
      '/app/update-policy',
      queryParameters: {
        'platform': 'android',
        'version_code': versionCode,
      },
      options: Options(
        sendTimeout: const Duration(seconds: 4),
        receiveTimeout: const Duration(seconds: 4),
      ),
    );
    final data = response.data;
    if (data is Map<String, dynamic>) {
      return AppUpdatePolicy.fromJson(data);
    }
    if (data is Map) {
      return AppUpdatePolicy.fromJson(Map<String, dynamic>.from(data));
    }
    return const AppUpdatePolicy();
  }
}

enum AppUpdateMode {
  none,
  flexible,
  immediate,
}

class AppUpdatePolicy {
  const AppUpdatePolicy({
    this.latestVersionCode = 0,
    this.minimumSupportedVersionCode = 0,
    this.mode = AppUpdateMode.none,
    this.updateRequired = false,
    this.message,
  });

  final int latestVersionCode;
  final int minimumSupportedVersionCode;
  final AppUpdateMode mode;
  final bool updateRequired;
  final String? message;

  factory AppUpdatePolicy.fromJson(Map<String, dynamic> json) {
    final modeRaw = (json['mode'] ?? 'none').toString().toLowerCase();
    final mode = switch (modeRaw) {
      'immediate' => AppUpdateMode.immediate,
      'flexible' => AppUpdateMode.flexible,
      _ => AppUpdateMode.none,
    };
    return AppUpdatePolicy(
      latestVersionCode: _asInt(json['latest_version_code']),
      minimumSupportedVersionCode:
          _asInt(json['minimum_supported_version_code']),
      mode: mode,
      updateRequired: json['update_required'] == true,
      message: json['message']?.toString(),
    );
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

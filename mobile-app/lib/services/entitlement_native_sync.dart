import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'entitlement_push_handler.dart';

/// Нативный Android → Dart: [EntitlementAuthSyncBridge] / SharedPreferences fallback.
class EntitlementNativeSync {
  EntitlementNativeSync._();

  static const MethodChannel _channel =
      MethodChannel('com.granivpn.mobile/entitlement_sync');

  static bool _dartHandlerRegistered = false;

  /// Регистрирует приёмник вызовов из Kotlin ([refreshAuthAfterEntitlement]).
  static void registerDartSideHandler() {
    if (_dartHandlerRegistered) {
      return;
    }
    _dartHandlerRegistered = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'refreshAuthAfterEntitlement') {
        final args = call.arguments;
        final src = args is Map ? args['source']?.toString() : null;
        await EntitlementPushHandler.syncAuthWithControlPlane(
          source: src ?? 'native_refreshAuthAfterEntitlement',
        );
        return null;
      }
      throw MissingPluginException();
    });
  }

  /// Считывает флаг из нативных prefs (если engine не был в кэше во время FCM).
  static Future<void> drainPendingFromNativePrefs() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      final raw = await _channel.invokeMethod<dynamic>('takePendingEntitlementAuthSync');
      if (raw is! Map) {
        return;
      }
      final pending = raw['pending'] == true;
      if (!pending) {
        return;
      }
      final src = raw['source']?.toString();
      await EntitlementPushHandler.syncAuthWithControlPlane(
        source: (src != null && src.isNotEmpty) ? src : 'native_prefs_pending',
      );
    } catch (e, st) {
      debugPrint('EntitlementNativeSync.drainPending: $e\n$st');
    }
  }
}

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';

import 'auth_service.dart';
import 'entitlement_push_contract.dart';
import 'native_vpn_service.dart';
import 'vpn_service.dart';

/// Реакция на FCM data (foreground / background Dart / iOS).
///
/// После native disconnect подтягивает `/auth/me` через [AuthService.refreshUserStatus],
/// если [AuthService] доступен в текущем isolate (основной UI; в отдельном FCM-isolate вызов тихо пропускается).
class EntitlementPushHandler {
  EntitlementPushHandler._();

  static Future<void> handleFcmData(
    Map<String, dynamic> data, {
    required String source,
  }) async {
    final shouldStopVpn = EntitlementPushContract.mapRequestsVpnStop(data);
    final shouldLogoutDevice =
        EntitlementPushContract.mapRequestsDeviceLogout(data);
    final shouldShowDeviceLimit =
        EntitlementPushContract.mapReportsDeviceLimit(data);
    final shouldRefreshAccess = shouldStopVpn ||
        shouldLogoutDevice ||
        shouldShowDeviceLimit ||
        EntitlementPushContract.mapRequestsAccessRefresh(data);
    if (!shouldRefreshAccess) {
      return;
    }
    // Device limit is a blocking user action. Mark it before awaiting native
    // VPN stop/cleanup so the shell can open the device-management modal
    // immediately instead of waiting for a potentially slow disconnect path.
    if (shouldShowDeviceLimit) {
      _markDeviceLimit(data, source: source);
    }
    if (shouldStopVpn) {
      final reasonRaw = data[EntitlementPushContract.reasonKey];
      final reason = reasonRaw != null && reasonRaw.toString().trim().isNotEmpty
          ? reasonRaw.toString().trim()
          : 'entitlement_revoked';
      try {
        await NativeVpnService.disconnectAmneziaWg(
          reason: reason,
          source: source,
        );
      } catch (e, st) {
        debugPrint(
          'EntitlementPushHandler: AmneziaWG disconnect failed '
          '($source): $e\n$st',
        );
      }
      try {
        await NativeVpnService.disconnect(
          reason: reason,
          source: source,
        );
      } catch (e, st) {
        debugPrint(
            'EntitlementPushHandler: disconnect failed ($source): $e\n$st');
      }
    }
    if (shouldLogoutDevice) {
      await _logoutRemovedDevice(source: source);
      return;
    }
    await syncAuthWithControlPlane(source: source);
  }

  static void _markDeviceLimit(
    Map<String, dynamic> data, {
    required String source,
  }) {
    int? parseFirstInt(List<String> keys) {
      for (final key in keys) {
        final raw = data[key]?.toString().trim();
        if (raw == null || raw.isEmpty) continue;
        final parsed = int.tryParse(raw);
        if (parsed != null) return parsed;
      }
      return null;
    }

    try {
      final getIt = GetIt.instance;
      if (!getIt.isRegistered<AuthService>()) {
        return;
      }
      final messageRaw = data['message']?.toString().trim();
      final message = messageRaw != null && messageRaw.isNotEmpty
          ? messageRaw
          : 'Превышен лимит устройств. Удалите лишнее устройство для продолжения.';
      final limit = parseFirstInt(const ['device_limit', 'limit']);
      final currentCount =
          parseFirstInt(const ['device_count', 'current_count']);
      getIt<AuthService>().setPendingDeviceLimit(
        DeviceLimitException(
          message,
          limit: limit,
          currentCount: currentCount,
        ),
      );
      debugPrint(
        'EntitlementPushHandler: device limit marked '
        '(source=$source event_id=${data['event_id']} '
        'current_count=$currentCount limit=$limit)',
      );
    } catch (e, st) {
      debugPrint(
        'EntitlementPushHandler: device limit mark failed '
        '(source=$source): $e\n$st',
      );
    }
  }

  static Future<void> _logoutRemovedDevice({required String source}) async {
    try {
      final getIt = GetIt.instance;
      if (getIt.isRegistered<VpnService>()) {
        final vpn = getIt<VpnService>();
        vpn.resetSession();
        await vpn.clearXrayConfigCache();
      }
      if (!getIt.isRegistered<AuthService>()) {
        return;
      }
      await getIt<AuthService>().logout();
      debugPrint(
          'EntitlementPushHandler: removed device logout ok (source=$source)');
    } catch (e, st) {
      debugPrint(
        'EntitlementPushHandler: removed device logout failed (source=$source): $e\n$st',
      );
    }
  }

  /// Событие «права на сервере изменились» — `/auth/me` без [BuildContext] (GetIt + нативный bridge).
  static Future<void> syncAuthWithControlPlane({required String source}) async {
    try {
      final getIt = GetIt.instance;
      if (!getIt.isRegistered<AuthService>()) {
        return;
      }
      await getIt<AuthService>().refreshUserStatus(force: true);
      debugPrint(
          'EntitlementPushHandler: refreshUserStatus ok (source=$source)');
    } catch (e, st) {
      debugPrint(
        'EntitlementPushHandler: refreshUserStatus skipped/failed (source=$source): $e\n$st',
      );
    }
  }
}

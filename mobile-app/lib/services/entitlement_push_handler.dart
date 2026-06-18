import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';

import 'auth_service.dart';
import 'entitlement_push_contract.dart';
import 'native_vpn_service.dart';

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
    final shouldRefreshAccess =
        shouldStopVpn || EntitlementPushContract.mapRequestsAccessRefresh(data);
    if (!shouldRefreshAccess) {
      return;
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
    await syncAuthWithControlPlane(source: source);
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

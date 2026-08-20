/// Контракт data payload FCM для событийного отключения VPN.
/// Должен совпадать с [EntitlementFcmReceiver] (Android) и бэкендом.
class EntitlementPushContract {
  EntitlementPushContract._();

  static const String actionKey = 'grani_action';
  static const String reasonKey = 'reason';
  static const String stopVpn = 'stop_vpn';
  static const String accessChanged = 'access_changed';

  /// Only these server-side entitlement reasons may stop an active VPN tunnel.
  /// Generic/transient access checks such as `subscription_required` must only
  /// refresh auth state and never tear down a working tunnel by themselves.
  static const Set<String> vpnStopReasons = {
    'subscription_expired',
    'subscription_revoked',
    'trial_ended',
    'access_expired',
    'logout',
    'auth_lost',
    'device_limit',
    'device_limit_exceeded',
    'device_revoked',
  };

  static const Set<String> deviceLimitEvents = {
    'device_limit',
    'device_limit_exceeded',
  };

  static const Set<String> accessGrantedEvents = {
    'payment_completed',
    'trial_activated',
    'subscription_activated',
    accessChanged,
  };

  static bool mapRequestsDeviceLogout(Map<String, dynamic> data) {
    final event = data['event']?.toString().trim();
    final reason = data[reasonKey]?.toString().trim();
    if (event == 'device_revoked' || reason == 'device_revoked') {
      return true;
    }
    final logout = data['logout']?.toString().trim().toLowerCase();
    final cleanup = data['cleanup']?.toString().trim().toLowerCase();
    return logout == 'true' || cleanup == 'true';
  }

  static bool mapReportsDeviceLimit(Map<String, dynamic> data) {
    final event = data['event']?.toString().trim();
    final reason = data[reasonKey]?.toString().trim();
    final code = data['code']?.toString().trim();
    final showDeviceLimit =
        data['show_device_limit']?.toString().trim().toLowerCase();
    return deviceLimitEvents.contains(event) ||
        reason == 'device_limit' ||
        reason == 'device_limit_exceeded' ||
        code == 'DEVICE_LIMIT_EXCEEDED' ||
        showDeviceLimit == 'true';
  }

  /// Все значения data в FCM — строки.
  static bool mapRequestsVpnStop(Map<String, dynamic> data) {
    final raw = data[actionKey];
    if (raw == null) return false;
    final a = raw.toString().trim();
    if (a != stopVpn) return false;
    final reasonRaw = data[reasonKey];
    if (reasonRaw == null) return false;
    return vpnStopReasons.contains(reasonRaw.toString().trim());
  }

  static bool mapRequestsAccessRefresh(Map<String, dynamic> data) {
    if (data[actionKey]?.toString().trim() == stopVpn) {
      return true;
    }
    final raw = data['event'];
    if (raw == null) return false;
    return accessGrantedEvents.contains(raw.toString().trim());
  }
}

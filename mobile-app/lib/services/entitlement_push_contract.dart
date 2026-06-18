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
    'device_revoked',
  };

  static const Set<String> accessGrantedEvents = {
    'trial_activated',
    'subscription_activated',
    accessChanged,
  };

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

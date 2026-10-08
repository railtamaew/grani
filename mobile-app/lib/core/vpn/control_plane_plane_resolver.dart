import 'vpn_orchestration_spec.dart';

/// Детерминированное сопоставление HTTP path → [ControlPlanePlane] (один path → один plane).
class ControlPlanePlaneResolver {
  ControlPlanePlaneResolver._();

  static String _pathOnly(String path) {
    final p = path.trim();
    final q = p.indexOf('?');
    return q >= 0 ? p.substring(0, q) : p;
  }

  /// Both durable queues must deliver terminal events after a failed connection.
  static bool isDurableDiagnosticsPath(String path) {
    final p = _pathOnly(path).toLowerCase();
    return p == '/simple-vpn/logs/batch' ||
        p == '/simple-vpn/product-telemetry';
  }

  /// API path вида /vpn/servers или полный URL — для относительных путей бэкенда.
  static ControlPlanePlane planeForApiPath(String path) {
    final p = _pathOnly(path).toLowerCase();
    if (p.startsWith('/auth/')) {
      return ControlPlanePlane.auth;
    }
    if (p == '/vpn/bootstrap') {
      return ControlPlanePlane.bootstrap;
    }
    if (p == '/vpn/logs/send' ||
        p == '/simple-vpn/logs' ||
        p == '/simple-vpn/logs/batch' ||
        p == '/simple-vpn/product-telemetry') {
      return ControlPlanePlane.logging;
    }
    return ControlPlanePlane.vpnControl;
  }

  /// Внешние probe URL (ipify, health-check) — тот же plane, что и контроль VPN после COMMIT.
  static ControlPlanePlane planeForExternalProbeUri(Uri uri) {
    return ControlPlanePlane.vpnControl;
  }
}

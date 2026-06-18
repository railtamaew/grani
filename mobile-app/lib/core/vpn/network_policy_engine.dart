import '../vpn_state_machine.dart';
import 'vpn_orchestration_runtime.dart';
import 'vpn_orchestration_spec.dart';

/// Решение Policy Engine для одного запроса control-plane.
class PolicyDecision {
  const PolicyDecision({
    required this.allowed,
    required this.route,
    required this.ownership,
    this.denyReason,
  });

  final bool allowed;
  final NetworkRouteHint route;
  final NetworkOwnership ownership;
  final String? denyReason;

  static PolicyDecision deny(String reason) => PolicyDecision(
        allowed: false,
        route: NetworkRouteHint.direct,
        ownership: NetworkOwnership.restricted,
        denyReason: reason,
      );
}

/// STATE × PLANE → allow/deny и подсказка маршрута (детерминированно).
class NetworkPolicyEngine {
  NetworkPolicyEngine._();
  static final NetworkPolicyEngine instance = NetworkPolicyEngine._();

  /// Закреплённый маршрут по plane (документация): auth / bootstrap / vpn_control / logging → direct.
  /// Совпадает с полем [PolicyDecision.route] при разрешённом запросе.
  NetworkRouteHint resolveDeterministicRouteHint(ControlPlanePlane plane) {
    switch (plane) {
      case ControlPlanePlane.auth:
      case ControlPlanePlane.bootstrap:
      case ControlPlanePlane.vpnControl:
      case ControlPlanePlane.logging:
        return NetworkRouteHint.direct;
    }
  }

  /// [connectivityDiagnosticsFlush]: оставлен для совместимости вызовов; после COMMIT
  /// POST /vpn/logs/send разрешён и в background (см. logging case).
  PolicyDecision evaluate(
    ControlPlanePlane plane, {
    bool connectivityDiagnosticsFlush = false,
  }) {
    final s = VpnOrchestrationRuntime.instance.vpnState;
    final bg = VpnOrchestrationRuntime.instance.isInBackground;

    final transaction =
        VpnOrchestrationRuntime.instance.isConnectTransactionActive;

    switch (plane) {
      case ControlPlanePlane.logging:
        if (connectivityDiagnosticsFlush) {
          return const PolicyDecision(
            allowed: true,
            route: NetworkRouteHint.direct,
            ownership: NetworkOwnership.sharedBudget,
          );
        }
        if (transaction) {
          return PolicyDecision.deny(
              'logging blocked during CONNECT transaction');
        }
        if (s != VpnConnectionState.connected) {
          return PolicyDecision.deny('logging only after COMMIT (connected)');
        }
        // После COMMIT: и в background (смешанные батчи с connectivity_probe и стадиями).
        return const PolicyDecision(
          allowed: true,
          route: NetworkRouteHint.direct,
          ownership: NetworkOwnership.sharedBudget,
        );

      case ControlPlanePlane.auth:
        // Refresh/access token во время connect может понадобиться (401); слот vpn_plane, не shared.
        if (transaction) {
          return const PolicyDecision(
            allowed: true,
            route: NetworkRouteHint.direct,
            ownership: NetworkOwnership.vpnPlane,
          );
        }
        return PolicyDecision(
          allowed: true,
          route: NetworkRouteHint.direct,
          ownership:
              bg ? NetworkOwnership.restricted : NetworkOwnership.sharedBudget,
        );

      case ControlPlanePlane.bootstrap:
        return PolicyDecision(
          allowed: true,
          route: NetworkRouteHint.direct,
          ownership: transaction
              ? NetworkOwnership.vpnPlane
              : NetworkOwnership.sharedBudget,
        );

      case ControlPlanePlane.vpnControl:
        return PolicyDecision(
          allowed: true,
          route: NetworkRouteHint.direct,
          ownership: transaction
              ? NetworkOwnership.vpnPlane
              : NetworkOwnership.sharedBudget,
        );
    }
  }
}

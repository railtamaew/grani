import 'vpn_orchestration_runtime.dart';
import 'vpn_orchestration_spec.dart';
import 'network_policy_engine.dart';

/// Глобальный лимит in-flight control-plane HTTP с учётом ownership в CONNECT transaction.
class NetworkBudgetController {
  NetworkBudgetController._();
  static final NetworkBudgetController instance = NetworkBudgetController._();

  int _inFlight = 0;

  int get inFlight => _inFlight;

  /// После успешного [NetworkPolicyEngine.evaluate] — проверка слотов.
  bool tryAcquireAfterPolicy(PolicyDecision decision) {
    if (!decision.allowed) {
      return false;
    }

    if (VpnOrchestrationRuntime.instance.isConnectTransactionActive) {
      if (decision.ownership == NetworkOwnership.sharedBudget) {
        return false;
      }
    }

    if (_inFlight >= VpnOrchestrationSpec.maxConcurrentControlPlaneHttp) {
      return false;
    }
    _inFlight++;
    return true;
  }

  void release() {
    if (_inFlight > 0) {
      _inFlight--;
    }
  }
}

import 'package:flutter/widgets.dart';

import '../vpn_state_machine.dart';

/// Единая точка чтения состояния для Policy Engine и Budget (обновляется из VpnService и lifecycle).
class VpnOrchestrationRuntime extends ChangeNotifier {
  VpnOrchestrationRuntime._();
  static final VpnOrchestrationRuntime instance = VpnOrchestrationRuntime._();

  VpnConnectionState _vpnState = VpnConnectionState.idle;
  AppLifecycleState _appLifecycle = AppLifecycleState.resumed;

  VpnConnectionState get vpnState => _vpnState;
  AppLifecycleState get appLifecycle => _appLifecycle;

  bool get isInBackground =>
      _appLifecycle == AppLifecycleState.paused ||
      _appLifecycle == AppLifecycleState.inactive ||
      _appLifecycle == AppLifecycleState.detached;

  /// В фазах подготовки туннеля до COMMIT (BEGIN…VERIFY).
  bool get isConnectTransactionActive {
    switch (_vpnState) {
      case VpnConnectionState.connecting:
      case VpnConnectionState.tunnelReady:
      case VpnConnectionState.tunnelVerifying:
        return true;
      default:
        return false;
    }
  }

  void setVpnState(VpnConnectionState state) {
    if (_vpnState == state) return;
    _vpnState = state;
    notifyListeners();
  }

  void setAppLifecycle(AppLifecycleState state) {
    if (_appLifecycle == state) return;
    _appLifecycle = state;
    notifyListeners();
  }
}

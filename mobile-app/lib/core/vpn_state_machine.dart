/// Упрощённое состояние для UI (warm/active/reconnecting без смешивания с transport-флагами).
enum VpnUiSessionState {
  off,
  connecting,
  reconnecting,
  connectedWarm,
  connectedActive,
  disconnecting,
  error,
}

/// Explicit VPN connection state and allowed transitions.
/// Single source of truth for connection state; use [VpnStateTransitions] to validate transitions.
enum VpnConnectionState {
  idle,
  connecting,
  /// TUN/Xray подняты, до проверки трафика/DNS — не COMMIT.
  tunnelReady,
  /// Идёт [_verifyConnection] / health — только после этого переход в [connected].
  tunnelVerifying,
  connected,
  disconnecting,
  disconnected,
  error,
}

/// Allowed state transitions. Prevents invalid flag combinations (e.g. connecting + connected).
class VpnStateTransitions {
  VpnStateTransitions._();

  static const _allowed = <VpnConnectionState, Set<VpnConnectionState>>{
    VpnConnectionState.idle: {VpnConnectionState.connecting, VpnConnectionState.error},
    VpnConnectionState.connecting: {
      VpnConnectionState.tunnelReady,
      VpnConnectionState.disconnecting,
      VpnConnectionState.error,
      VpnConnectionState.idle,
    },
    VpnConnectionState.tunnelReady: {
      VpnConnectionState.tunnelVerifying,
      VpnConnectionState.disconnecting,
      VpnConnectionState.error,
      VpnConnectionState.idle,
    },
    VpnConnectionState.tunnelVerifying: {
      VpnConnectionState.connected,
      VpnConnectionState.connecting,
      VpnConnectionState.disconnecting,
      VpnConnectionState.error,
      VpnConnectionState.idle,
    },
    VpnConnectionState.connected: {VpnConnectionState.disconnecting, VpnConnectionState.disconnected, VpnConnectionState.error},
    VpnConnectionState.disconnecting: {VpnConnectionState.disconnected, VpnConnectionState.connected, VpnConnectionState.error},
    VpnConnectionState.disconnected: {VpnConnectionState.connecting, VpnConnectionState.idle, VpnConnectionState.error},
    VpnConnectionState.error: {VpnConnectionState.idle, VpnConnectionState.connecting, VpnConnectionState.disconnected},
  };

  static bool canTransition(VpnConnectionState from, VpnConnectionState to) {
    return _allowed[from]?.contains(to) ?? false;
  }

  /// Maps state to flags for VpnService (isConnecting, isDisconnecting, isConnected).
  static (bool connecting, bool disconnecting, bool connected) toFlags(VpnConnectionState state) {
    switch (state) {
      case VpnConnectionState.connecting:
      case VpnConnectionState.tunnelReady:
      case VpnConnectionState.tunnelVerifying:
        return (true, false, false);
      case VpnConnectionState.connected:
        return (false, false, true);
      case VpnConnectionState.disconnecting:
        return (false, true, false);
      case VpnConnectionState.idle:
      case VpnConnectionState.disconnected:
      case VpnConnectionState.error:
        return (false, false, false);
    }
  }
}

extension VpnConnectionStateUi on VpnConnectionState {
  /// Базовая сводка для экранов (без учета трафика/интента переподключения).
  /// Для точного UI использовать вычисление в VpnService.vpnUiSessionState.
  VpnUiSessionState get toUiSession {
    switch (this) {
      case VpnConnectionState.idle:
      case VpnConnectionState.disconnected:
        return VpnUiSessionState.off;
      case VpnConnectionState.connecting:
      case VpnConnectionState.tunnelReady:
      case VpnConnectionState.tunnelVerifying:
        return VpnUiSessionState.connecting;
      case VpnConnectionState.connected:
        return VpnUiSessionState.connectedWarm;
      case VpnConnectionState.disconnecting:
        return VpnUiSessionState.disconnecting;
      case VpnConnectionState.error:
        return VpnUiSessionState.error;
    }
  }
}

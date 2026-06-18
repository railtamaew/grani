import '../../core/vpn_state_machine.dart';
import '../../widgets/button_connection.dart';

class ButtonConnectionStateMapper {
  const ButtonConnectionStateMapper._();

  static ButtonConnectionState fromVpnSessionState(
    VpnUiSessionState sessionState, {
    String? errorMessage,
  }) {
    switch (sessionState) {
      case VpnUiSessionState.connecting:
      case VpnUiSessionState.reconnecting:
        return ButtonConnectionState.connecting;
      case VpnUiSessionState.disconnecting:
        return ButtonConnectionState.disconnecting;
      case VpnUiSessionState.connectedWarm:
      case VpnUiSessionState.connectedActive:
        return ButtonConnectionState.on;
      case VpnUiSessionState.error:
      case VpnUiSessionState.off:
        if (errorMessage != null && errorMessage.isNotEmpty) {
          return ButtonConnectionState.error;
        }
        return ButtonConnectionState.off;
    }
  }
}

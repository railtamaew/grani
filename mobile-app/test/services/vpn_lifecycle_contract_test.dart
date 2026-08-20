import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/core/vpn/button_connection_state_mapper.dart';
import 'package:mobile_app/core/vpn/connection_action_orchestrator.dart';
import 'package:mobile_app/core/vpn/vpn_operation_guards.dart';
import 'package:mobile_app/core/vpn_state_machine.dart';
import 'package:mobile_app/widgets/button_connection.dart';

void main() {
  group('VPN lifecycle state contract', () {
    test('maps connection states to a single active flag set', () {
      expect(
        VpnStateTransitions.toFlags(VpnConnectionState.idle),
        (false, false, false),
      );
      expect(
        VpnStateTransitions.toFlags(VpnConnectionState.connecting),
        (true, false, false),
      );
      expect(
        VpnStateTransitions.toFlags(VpnConnectionState.tunnelReady),
        (true, false, false),
      );
      expect(
        VpnStateTransitions.toFlags(VpnConnectionState.tunnelVerifying),
        (true, false, false),
      );
      expect(
        VpnStateTransitions.toFlags(VpnConnectionState.connected),
        (false, false, true),
      );
      expect(
        VpnStateTransitions.toFlags(VpnConnectionState.disconnecting),
        (false, true, false),
      );
      expect(
        VpnStateTransitions.toFlags(VpnConnectionState.disconnected),
        (false, false, false),
      );
      expect(
        VpnStateTransitions.toFlags(VpnConnectionState.error),
        (false, false, false),
      );
    });

    test('allows expected connect and disconnect transitions', () {
      expect(
        VpnStateTransitions.canTransition(
          VpnConnectionState.connected,
          VpnConnectionState.disconnecting,
        ),
        isTrue,
      );
      expect(
        VpnStateTransitions.canTransition(
          VpnConnectionState.disconnecting,
          VpnConnectionState.disconnected,
        ),
        isTrue,
      );
      expect(
        VpnStateTransitions.canTransition(
          VpnConnectionState.disconnected,
          VpnConnectionState.connecting,
        ),
        isTrue,
      );
    });

    test('button mapper keeps UI states deterministic', () {
      expect(
        ButtonConnectionStateMapper.fromVpnSessionState(
          VpnUiSessionState.off,
        ),
        ButtonConnectionState.off,
      );
      expect(
        ButtonConnectionStateMapper.fromVpnSessionState(
          VpnUiSessionState.off,
          errorMessage: 'failed',
        ),
        ButtonConnectionState.error,
      );
      expect(
        ButtonConnectionStateMapper.fromVpnSessionState(
          VpnUiSessionState.connecting,
        ),
        ButtonConnectionState.connecting,
      );
      expect(
        ButtonConnectionStateMapper.fromVpnSessionState(
          VpnUiSessionState.reconnecting,
        ),
        ButtonConnectionState.connecting,
      );
      expect(
        ButtonConnectionStateMapper.fromVpnSessionState(
          VpnUiSessionState.connectedWarm,
        ),
        ButtonConnectionState.on,
      );
      expect(
        ButtonConnectionStateMapper.fromVpnSessionState(
          VpnUiSessionState.connectedActive,
        ),
        ButtonConnectionState.on,
      );
      expect(
        ButtonConnectionStateMapper.fromVpnSessionState(
          VpnUiSessionState.disconnecting,
        ),
        ButtonConnectionState.disconnecting,
      );
    });
  });

  group('Quick tile and disconnect guard contract', () {
    test('quick tile is an explicit user action even in background', () {
      final decision = VpnOperationGuards.evaluateDisconnect(
        isUserReason: true,
        isAllowedServiceReason: false,
        isInBackground: true,
        source: 'quick_tile',
        connectInProgress: false,
        sinceConnected: const Duration(seconds: 10),
        debounceWindow: const Duration(seconds: 8),
      );

      expect(decision.isAllowed, isTrue);
      expect(decision.code, isNull);
    });

    test('background user disconnect without explicit source is blocked', () {
      final decision = VpnOperationGuards.evaluateDisconnect(
        isUserReason: true,
        isAllowedServiceReason: false,
        isInBackground: true,
        source: 'unspecified',
        connectInProgress: false,
        sinceConnected: const Duration(seconds: 10),
        debounceWindow: const Duration(seconds: 8),
      );

      expect(decision.isAllowed, isFalse);
      expect(decision.code, 'background_non_explicit_user_action');
    });

    test('system panel is treated as an explicit background user action', () {
      final decision = VpnOperationGuards.evaluateDisconnect(
        isUserReason: true,
        isAllowedServiceReason: false,
        isInBackground: true,
        source: 'system_panel',
        connectInProgress: false,
        sinceConnected: const Duration(seconds: 10),
        debounceWindow: const Duration(seconds: 8),
      );

      expect(decision.isAllowed, isTrue);
    });

    test('disconnect is idempotently blocked while connect is in progress', () {
      final decision = VpnOperationGuards.evaluateDisconnect(
        isUserReason: true,
        isAllowedServiceReason: false,
        isInBackground: false,
        source: 'ui_tap',
        connectInProgress: true,
        sinceConnected: null,
        debounceWindow: const Duration(seconds: 8),
      );

      expect(decision.isAllowed, isFalse);
      expect(decision.code, 'connect_in_progress');
    });

    test('fresh post-connect accidental disconnect is debounced', () {
      final decision = VpnOperationGuards.evaluateDisconnect(
        isUserReason: true,
        isAllowedServiceReason: false,
        isInBackground: false,
        source: 'ui_tap',
        connectInProgress: false,
        sinceConnected: const Duration(seconds: 2),
        debounceWindow: const Duration(seconds: 8),
      );

      expect(decision.isAllowed, isFalse);
      expect(decision.code, 'post_connect_window');
    });

    test('service disconnect reasons stay allowed in background', () {
      final decision = VpnOperationGuards.evaluateDisconnect(
        isUserReason: false,
        isAllowedServiceReason: true,
        isInBackground: true,
        source: 'subscription_revoked',
        connectInProgress: false,
        sinceConnected: null,
        debounceWindow: const Duration(seconds: 8),
      );

      expect(decision.isAllowed, isTrue);
    });

    test('unknown non-user disconnect reason is rejected', () {
      final decision = VpnOperationGuards.evaluateDisconnect(
        isUserReason: false,
        isAllowedServiceReason: false,
        isInBackground: false,
        source: 'unknown_worker',
        connectInProgress: false,
        sinceConnected: null,
        debounceWindow: const Duration(seconds: 8),
      );

      expect(decision.isAllowed, isFalse);
      expect(decision.code, 'unsupported_disconnect_reason');
    });

    test('connection button states declare connect vs disconnect intent', () {
      expect(
        ConnectionActionOrchestrator.isConnectRequested(
          ButtonConnectionState.off,
        ),
        isTrue,
      );
      expect(
        ConnectionActionOrchestrator.isConnectRequested(
          ButtonConnectionState.error,
        ),
        isTrue,
      );
      expect(
        ConnectionActionOrchestrator.isDisconnectRequested(
          ButtonConnectionState.on,
        ),
        isTrue,
      );
      expect(
        ConnectionActionOrchestrator.isDisconnectRequested(
          ButtonConnectionState.connecting,
        ),
        isTrue,
      );
      expect(
        ConnectionActionOrchestrator.isDisconnectRequested(
          ButtonConnectionState.disconnecting,
        ),
        isTrue,
      );
    });
  });
}

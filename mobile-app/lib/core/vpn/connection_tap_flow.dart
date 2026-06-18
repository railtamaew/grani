import 'package:flutter/widgets.dart';

import '../../services/vpn_service.dart';
import '../../widgets/button_connection.dart';
import 'connection_action_orchestrator.dart';
import 'trial_connection_monitor.dart';

class ConnectionTapOutcome {
  const ConnectionTapOutcome({
    required this.action,
    required this.shouldGrantPermission,
  });

  final ConnectionUiAction action;
  final bool shouldGrantPermission;
}

class ConnectionTapFlow {
  ConnectionTapFlow({
    required ConnectionActionOrchestrator orchestrator,
    this.monitor,
    this.vpnService,
    this.permissionPolicy,
  }) : _orchestrator = orchestrator;

  final ConnectionActionOrchestrator _orchestrator;
  final TrialConnectionMonitor? monitor;
  final VpnService? vpnService;
  final bool Function(bool connectRequested, ConnectionUiAction action)?
      permissionPolicy;
  bool _connectTapInFlight = false;

  Future<ConnectionTapOutcome> handleTap(
    BuildContext context,
    ButtonConnectionState state, {
    void Function()? onConnectTimeout,
  }) async {
    final connectRequested = ConnectionActionOrchestrator.isConnectRequested(state);
    if (connectRequested && _connectTapInFlight) {
      return const ConnectionTapOutcome(
        action: ConnectionUiNoop(),
        shouldGrantPermission: false,
      );
    }
    if (monitor != null && vpnService != null && onConnectTimeout != null) {
      monitor!.onTapIntent(
        connectRequested: connectRequested,
        vpnService: vpnService!,
        onConnectTimeout: onConnectTimeout,
      );
    }

    if (connectRequested) {
      _connectTapInFlight = true;
    }
    late final ConnectionUiAction action;
    try {
      action = await _orchestrator.handleTap(context, state);
    } finally {
      if (connectRequested) {
        _connectTapInFlight = false;
      }
    }
    final shouldGrant = permissionPolicy?.call(connectRequested, action) ?? false;
    return ConnectionTapOutcome(
      action: action,
      shouldGrantPermission: shouldGrant,
    );
  }
}

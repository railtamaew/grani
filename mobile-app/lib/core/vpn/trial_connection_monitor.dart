import 'dart:async';

import '../../services/vpn_service.dart';

class TrialConnectionMonitor {
  TrialConnectionMonitor({
    this.connectTimeout = const Duration(seconds: 30),
  });

  final Duration connectTimeout;
  Timer? _connectionTimer;

  void onTapIntent({
    required bool connectRequested,
    required VpnService vpnService,
    required void Function() onConnectTimeout,
  }) {
    if (connectRequested) {
      _start(vpnService: vpnService, onConnectTimeout: onConnectTimeout);
      return;
    }
    cancel();
  }

  void _start({
    required VpnService vpnService,
    required void Function() onConnectTimeout,
  }) {
    _connectionTimer?.cancel();
    _connectionTimer = Timer(connectTimeout, () {
      if (!vpnService.isConnected && vpnService.isConnecting) {
        onConnectTimeout();
      }
    });
  }

  void cancel() {
    _connectionTimer?.cancel();
    _connectionTimer = null;
  }

  void dispose() {
    cancel();
  }
}

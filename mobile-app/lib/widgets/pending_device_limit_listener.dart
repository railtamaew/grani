import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/session/device_limit_flow.dart';
import '../services/auth_service.dart';
import '../services/vpn_service.dart';

/// Реагирует на [AuthService.setPendingDeviceLimit] / [notifyListeners], чтобы показать лимит устройств
/// после того, как фоновая регистрация устройства завершилась уже на главном shell (не one-shot при mount).
class PendingDeviceLimitListener extends StatefulWidget {
  const PendingDeviceLimitListener({super.key, required this.child});

  final Widget child;

  @override
  State<PendingDeviceLimitListener> createState() =>
      _PendingDeviceLimitListenerState();
}

class _PendingDeviceLimitListenerState extends State<PendingDeviceLimitListener> {
  AuthService? _auth;
  bool _modalInFlight = false;

  void _onAuthChanged() {
    if (!mounted) return;
    final auth = _auth;
    if (auth == null || !auth.hasPendingDeviceLimit) return;
    if (_modalInFlight) return;
    _modalInFlight = true;
    unawaited(_runPendingDeviceLimitFlow());
  }

  Future<void> _runPendingDeviceLimitFlow() async {
    try {
      if (!mounted) return;
      final authService = context.read<AuthService>();
      final vpnService = context.read<VpnService>();
      await handlePendingDeviceLimitAfterAuth(
        context: context,
        authService: authService,
        vpnService: vpnService,
      );
    } finally {
      if (mounted) _modalInFlight = false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final auth = context.read<AuthService>();
      _auth = auth;
      auth.addListener(_onAuthChanged);
      _onAuthChanged();
    });
  }

  @override
  void dispose() {
    _auth?.removeListener(_onAuthChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

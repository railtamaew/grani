import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../screens/main/clean_amnezia_home_screen.dart';
import '../screens/trial_ended_screen.dart';

/// Тело VPN-shell: активный доступ (подписка или trial) использует единый
/// SimpleVpn/GRANIwg экран, чтобы серверы/протоколы не расходились между режимами.
/// Маршрут `/main` остаётся в [MainContentScreen].
class VpnShellBody extends StatelessWidget {
  const VpnShellBody({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthService>(
      builder: (context, authService, _) {
        if (authService.hasActiveSubscription) {
          return const CleanAmneziaHomeScreen();
        }
        final trialSecondsLeft = authService.trialSecondsLeft ?? 0;
        if (trialSecondsLeft <= 0) {
          return const TrialEndedScreen(mode: SubscriptionScreenMode.expired);
        }
        return const CleanAmneziaHomeScreen();
      },
    );
  }
}

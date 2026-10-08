import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../screens/main_content_screen.dart';
import '../services/auth_service.dart';
import 'tv_account_screen.dart';
import 'tv_devices_screen.dart';
import 'tv_paywall_screen.dart';
import 'tv_privacy_screen.dart';
import 'tv_sign_in_screen.dart';
import 'tv_split_tunnel_screen.dart';

class TvRoutes {
  TvRoutes._();
  static Route<dynamic> create(RouteSettings settings) =>
      MaterialPageRoute<dynamic>(
        settings: settings,
        builder: (context) => switch (settings.name) {
          '/main' ||
          '/home' ||
          '/connected' ||
          '/connecting' ||
          '/trial' ||
          '/trial-connected' ||
          '/trial-connecting' ||
          '/post-auth-preparation' =>
            const MainContentScreen(),
          '/profile' => const TvAccountScreen(),
          '/devices' => const TvDevicesScreen(),
          '/device-limit' => const TvDevicesScreen(resolveLimit: true),
          '/split-tunnel' => const TvSplitTunnelScreen(),
          '/privacy' => const TvPrivacyScreen(),
          '/trial-ended' ||
          '/subscription' ||
          '/payment' ||
          '/payment-result' =>
            const TvPaywallScreen(),
          '/' || '/auth-email' || '/auth-code' => const TvSignInScreen(),
          _ => context.read<AuthService>().isAuthenticated
              ? const MainContentScreen()
              : const TvSignInScreen(),
        },
      );
}

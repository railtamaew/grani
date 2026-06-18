import 'package:flutter/material.dart';

import '../widgets/vpn_shell_body.dart';

/// Основной Grani shell после авторизации.
/// Протокольный MVP теперь AmneziaWG; Xray оставлен архивным/R&D путем.
class MainContentScreen extends StatelessWidget {
  const MainContentScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PopScope(
      canPop: false,
      child: VpnShellBody(),
    );
  }
}

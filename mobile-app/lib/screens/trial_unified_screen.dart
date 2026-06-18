import 'package:flutter/material.dart';

import 'main/clean_amnezia_home_screen.dart';

/// Compatibility wrapper for old trial routes/imports.
///
/// Trial and active subscription must use the same SimpleVpnController path.
/// Keeping this class avoids accidental reintroduction of the legacy
/// VpnService-based trial button while old imports still compile.
class TrialUnifiedScreen extends StatelessWidget {
  const TrialUnifiedScreen({super.key});

  @override
  Widget build(BuildContext context) => const CleanAmneziaHomeScreen();
}

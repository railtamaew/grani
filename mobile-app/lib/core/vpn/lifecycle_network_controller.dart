import 'package:flutter/widgets.dart';

import 'vpn_orchestration_runtime.dart';

/// Связывает [AppLifecycleState] с оркестрацией (Policy / budget видят фон).
class LifecycleNetworkController {
  LifecycleNetworkController._();

  /// Вызывать из корня приложения ([WidgetsBindingObserver.didChangeAppLifecycleState]).
  static void onAppLifecycleChanged(AppLifecycleState state) {
    VpnOrchestrationRuntime.instance.setAppLifecycle(state);
  }
}

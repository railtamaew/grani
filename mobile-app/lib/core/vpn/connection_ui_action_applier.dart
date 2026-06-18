import 'package:flutter/material.dart';

import 'connection_action_orchestrator.dart';

class ConnectionUiActionApplier {
  const ConnectionUiActionApplier._();

  static void apply({
    required BuildContext context,
    required ConnectionUiAction action,
    required void Function(String?) setErrorMessage,
    Duration? autoHideErrorAfter,
  }) {
    switch (action) {
      case ConnectionUiClearError():
        setErrorMessage(null);
        return;
      case ConnectionUiShowError(message: final msg):
        setErrorMessage(msg);
        if (autoHideErrorAfter != null) {
          Future.delayed(autoHideErrorAfter, () {
            if (context.mounted) {
              setErrorMessage(null);
            }
          });
        }
        return;
      case ConnectionUiNavigateSubscriptionExpired():
        ConnectionActionOrchestrator.navigateToExpiredSubscription(context);
        return;
      case ConnectionUiNoop():
        return;
    }
  }
}

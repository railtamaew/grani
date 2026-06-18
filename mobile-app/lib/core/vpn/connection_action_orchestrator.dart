import 'package:flutter/widgets.dart';

import '../../core/session/device_limit_flow.dart';
import '../../l10n/l10n.dart';
import '../../services/auth_service.dart';
import '../../services/vpn_service.dart';
import '../../use_cases/connect_vpn_use_case.dart';
import '../../widgets/button_connection.dart';
import '../../screens/trial_ended_screen.dart' show SubscriptionScreenMode;

sealed class ConnectionUiAction {
  const ConnectionUiAction();
}

class ConnectionUiNoop extends ConnectionUiAction {
  const ConnectionUiNoop();
}

class ConnectionUiClearError extends ConnectionUiAction {
  const ConnectionUiClearError();
}

class ConnectionUiShowError extends ConnectionUiAction {
  final String message;
  const ConnectionUiShowError(this.message);
}

class ConnectionUiNavigateSubscriptionExpired extends ConnectionUiAction {
  const ConnectionUiNavigateSubscriptionExpired();
}

/// Executes business actions for the connection button tap.
/// UI widgets should map [ConnectionUiAction] to banners/navigation/state changes.
class ConnectionActionOrchestrator {
  ConnectionActionOrchestrator({
    required VpnService vpnService,
    required AuthService authService,
    required this.startTrialTimer,
    required this.disconnectSource,
  })  : _vpnService = vpnService,
        _authService = authService,
        _useCase = ConnectVpnUseCase(
          vpnService: vpnService,
          authService: authService,
        );

  final VpnService _vpnService;
  final AuthService _authService;
  final ConnectVpnUseCase _useCase;
  final bool startTrialTimer;
  final String disconnectSource;

  Future<ConnectionUiAction> handleTap(
    BuildContext context,
    ButtonConnectionState state,
  ) async {
    if (isDisconnectRequested(state)) {
      await _vpnService.disconnect(source: disconnectSource);
      return const ConnectionUiNoop();
    }
    return _handleConnect(context);
  }

  Future<ConnectionUiAction> _handleConnect(BuildContext context) async {
    final result = await _useCase.connect(startTrialTimer: startTrialTimer);
    if (!context.mounted) return const ConnectionUiNoop();

    if (result is ConnectSuccess) {
      return const ConnectionUiClearError();
    }
    if (result is ConnectFailure) {
      return ConnectionUiShowError(result.userMessage);
    }
    if (result is ConnectNoSubscription) {
      return const ConnectionUiNavigateSubscriptionExpired();
    }
    if (result is ConnectDeviceLimit) {
      ConnectionUiAction action = const ConnectionUiNoop();
      await handleConnectDeviceLimitFromUseCase(
        context: context,
        result: result,
        authService: _authService,
        vpnService: _vpnService,
        onResolvedRetryConnect: () => _useCase.connect(startTrialTimer: startTrialTimer),
        onRetryCompleted: (retry) {
          if (retry is ConnectSuccess) {
            action = const ConnectionUiClearError();
            return;
          }
          if (retry is ConnectFailure) {
            action = ConnectionUiShowError(retry.userMessage);
            return;
          }
          action = ConnectionUiShowError(context.l10n.connectRetryGeneric);
        },
      );
      return action;
    }

    return const ConnectionUiNoop();
  }

  static void navigateToExpiredSubscription(BuildContext context) {
    Navigator.pushNamedAndRemoveUntil(
      context,
      '/subscription',
      (_) => false,
      arguments: SubscriptionScreenMode.expired,
    );
  }

  static bool isConnectRequested(ButtonConnectionState state) =>
      state == ButtonConnectionState.off || state == ButtonConnectionState.error;

  static bool isDisconnectRequested(ButtonConnectionState state) =>
      state == ButtonConnectionState.connecting ||
      state == ButtonConnectionState.disconnecting ||
      state == ButtonConnectionState.on;

  static bool isPermissionDeniedMessage(String message) =>
      message.contains('разрешение') || message.contains('Разрешение');

  static bool shouldGrantTrialPermission({
    required bool connectRequested,
    required ConnectionUiAction action,
  }) {
    if (!connectRequested || action is ConnectionUiNoop) return false;
    if (action case ConnectionUiShowError(message: final msg)) {
      return !isPermissionDeniedMessage(msg);
    }
    return true;
  }
}

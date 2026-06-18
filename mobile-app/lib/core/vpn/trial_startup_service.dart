import 'dart:async';

import '../../services/auth_service.dart';
import '../../services/vpn_service.dart';

class TrialStartupResult {
  const TrialStartupResult({
    required this.errorMessage,
    required this.isAuthError,
    required this.isTimeoutError,
    required this.isNetworkError,
  });

  final String? errorMessage;
  final bool isAuthError;
  final bool isTimeoutError;
  final bool isNetworkError;

  bool get hasError => errorMessage != null && errorMessage!.isNotEmpty;
}

class TrialStartupService {
  const TrialStartupService._();

  static Future<TrialStartupResult> initializeVpn({
    required VpnService vpnService,
    AuthService? authService,
    Duration refreshTimeout = const Duration(seconds: 20),
  }) async {
    try {
      await vpnService.syncConnectionStateWithNative();
      if (authService != null) {
        await vpnService.refreshControlPlaneSnapshot(authService).timeout(
              refreshTimeout,
              onTimeout: () => throw TimeoutException(
                'Превышено время ожидания загрузки snapshot',
              ),
            );
      } else {
        await vpnService.refreshServers().timeout(
            refreshTimeout,
            onTimeout: () => throw TimeoutException(
              'Превышено время ожидания загрузки серверов',
            ),
          );
      }
      if (vpnService.servers.isEmpty) {
        return const TrialStartupResult(
          errorMessage: 'servers_empty',
          isAuthError: false,
          isTimeoutError: false,
          isNetworkError: false,
        );
      }
      if (vpnService.selectedServer == null && vpnService.servers.isNotEmpty) {
        vpnService.selectServer(vpnService.servers.first);
      }
      return const TrialStartupResult(
        errorMessage: null,
        isAuthError: false,
        isTimeoutError: false,
        isNetworkError: false,
      );
    } catch (error) {
      final msg = error.toString();
      return TrialStartupResult(
        errorMessage: msg,
        isAuthError: msg.contains('401') || msg.contains('Unauthorized'),
        isTimeoutError: msg.contains('timeout') || msg.contains('Timeout'),
        isNetworkError: msg.contains('Network') || msg.contains('Socket'),
      );
    }
  }
}

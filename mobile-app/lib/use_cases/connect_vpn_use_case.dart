import 'package:flutter/foundation.dart';
import '../core/errors/error_handler.dart';
import '../l10n/localized_messages.dart';
import '../services/vpn_service.dart';
import '../services/auth_service.dart';
import '../services/native_vpn_service.dart';
/// Result of running the connect flow.
sealed class ConnectResult {
  const ConnectResult();
}

class ConnectSuccess extends ConnectResult {
  const ConnectSuccess();
}

class ConnectFailure extends ConnectResult {
  final String userMessage;
  const ConnectFailure(this.userMessage);
}

/// No subscription/trial — redirect to tariff or trial-ended screen.
class ConnectNoSubscription extends ConnectResult {
  final String message;
  ConnectNoSubscription([this.message = '']);

  factory ConnectNoSubscription.localized() =>
      ConnectNoSubscription(LocalizedMessages.connectNoSubscription);
}

/// Device limit exceeded; UI should show device picker and then call [ConnectVpnUseCase.deactivateAndRetry].
class ConnectDeviceLimit extends ConnectResult {
  final String message;
  final List<dynamic> devices;
  const ConnectDeviceLimit(this.message, this.devices);
}

/// Single use case for "connect to VPN": ensure server → connect, with unified error handling.
/// Screens call this instead of duplicating logic in HomeScreen / TrialUnifiedScreen.
class ConnectVpnUseCase {
  ConnectVpnUseCase({
    required VpnService vpnService,
    required AuthService authService,
  })  : _vpnService = vpnService,
        _authService = authService,
        _errorHandler = ErrorHandler();

  final VpnService _vpnService;
  final AuthService _authService;
  final ErrorHandler _errorHandler;

  /// Runs the full connect flow. Returns [ConnectSuccess], [ConnectFailure](userMessage), [ConnectNoSubscription], or [ConnectDeviceLimit].
  /// [startTrialTimer]: при false не запускается таймер триала (для пользователей с подпиской).
  ///
  /// [DeviceLimitException] из [VpnService.connect] (регистрация устройства до /vpn/connect) **прерывает** поток:
  /// возвращается [ConnectDeviceLimit], до успешного [VpnService.isConnected] выполнение не доходит.
  Future<ConnectResult> connect({bool startTrialTimer = true}) async {
    try {
      if (_authService.hasPendingDeviceLimit) {
        final msg = _authService.pendingDeviceLimitMessage ?? '';
        final dev = _authService.pendingDeviceLimitDevices;
        return ConnectDeviceLimit(
          msg.isNotEmpty ? msg : 'Device limit',
          dev.isNotEmpty ? dev : await _fetchDevices(),
        );
      }
      // Проверка подписки/триала перед подключением — не вызываем API без доступа
      if (!_authService.hasActiveSubscription) {
        final trialLeft = _authService.trialSecondsLeft ?? 0;
        if (trialLeft <= 0) {
          return ConnectNoSubscription.localized();
        }
      }
      if (_vpnService.selectedServer == null || _vpnService.servers.isEmpty) {
        await _vpnService.refreshServers();
        if (_vpnService.servers.isEmpty) {
          return ConnectFailure(LocalizedMessages.serversLoadFailedForConnect);
        }
        if (_vpnService.selectedServer == null && _vpnService.servers.isNotEmpty) {
          _vpnService.selectServer(_vpnService.servers.first);
        }
      }
      final server = _vpnService.selectedServer;
      if (server == null) {
        return ConnectFailure(LocalizedMessages.selectServerBeforeConnect);
      }
      // VpnService.connect() вызывает _autoSelectServerAndProtocol() — выбирает supportedProtocols при несовпадении
      await _vpnService.connect(startTrialTimer: startTrialTimer);
      if (_vpnService.isConnected) {
        return const ConnectSuccess();
      }
      final lastError = _vpnService.lastConnectionErrorMessage;
      if (lastError != null && _isAuthError(lastError)) {
        await _forceLogoutIfNeeded();
      }
      return ConnectFailure(
        lastError != null && lastError.isNotEmpty
            ? lastError
            : LocalizedMessages.connectFailureRetry,
      );
    } on DeviceLimitException catch (e) {
      return ConnectDeviceLimit(
        e.message,
        e.devices.isNotEmpty ? e.devices : await _fetchDevices(),
      );
    } catch (e) {
      debugPrint('ConnectVpnUseCase: $e');
      final msg = _errorHandler.userMessageForConnectionError(e);
      if (_isAuthError(e.toString()) || _isAuthError(msg)) {
        await _forceLogoutIfNeeded();
      }
      return ConnectFailure(msg);
    }
  }

  /// After user picks a device to deactivate, call this then [connect] again.
  Future<bool> deactivateAndRetry(String deviceId, {bool startTrialTimer = true}) async {
    try {
      await _vpnService.deactivateDeviceWithAuth(deviceId);
      await _vpnService.connect(startTrialTimer: startTrialTimer);
      return _vpnService.isConnected;
    } on DeviceLimitException {
      rethrow;
    } catch (_) {
      return false;
    }
  }

  Future<List<dynamic>> _fetchDevices() async {
    try {
      return await _vpnService.fetchDevicesWithAuth();
    } catch (_) {
      return [];
    }
  }

  static bool _isAuthError(String s) {
    final lower = s.toLowerCase();
    return lower.contains('401') ||
        lower.contains('unauthorized') ||
        lower.contains('авторизац') ||
        lower.contains('требуется повторная') ||
        lower.contains('необходима авторизация') ||
        lower.contains('сессия истекла');
  }

  Future<void> _forceLogoutIfNeeded() async {
    try {
      if (_authService.isAuthenticated) await _authService.logout();
    } catch (_) {}
  }
}

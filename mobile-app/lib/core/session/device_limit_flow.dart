import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../screens/device_limit_screen.dart' show DeviceLimitResult, showDeviceLimitModal;
import '../../services/auth_service.dart';
import '../../services/native_vpn_service.dart' show DeviceLimitException;
import '../../services/vpn_service.dart';
import '../../use_cases/connect_vpn_use_case.dart';

Future<List<dynamic>> _fetchDevicesSafe(VpnService vpnService) async {
  try {
    return await vpnService.fetchDevicesWithAuth();
  } catch (e, st) {
    // Пустой список здесь означает «модалка сама перезапросит» в initState; логируем причину.
    debugPrint('device_limit_flow: fetchDevicesWithAuth failed: $e\n$st');
    return [];
  }
}

Future<void> _showRegisterExhaustedDialog(BuildContext context) async {
  final l10n = AppLocalizations.of(context);
  if (l10n == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.errorNetworkGeneric),
      content: Text(l10n.connectRetryGeneric),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
        ),
      ],
    ),
  );
}

/// Блокирующая регистрация устройства до успеха или выхода. Вызывать **до** [Navigator] на `/main`.
/// Не более [maxRegisterAttempts] вызовов [VpnService.ensureDeviceRegistered]; затем fallback UI.
Future<bool> registerDeviceUntilOkWithModal({
  required BuildContext context,
  required AuthService authService,
  required VpnService vpnService,
  required String token,
  int maxRegisterAttempts = 3,
}) async {
  for (var regAttempts = 1; regAttempts <= maxRegisterAttempts; regAttempts++) {
    try {
      await vpnService.ensureDeviceRegistered(token);
      authService.clearPendingDeviceLimit();
      return true;
    } on DeviceLimitException catch (e) {
      if (regAttempts >= maxRegisterAttempts) {
        if (context.mounted) await _showRegisterExhaustedDialog(context);
        return false;
      }
      if (!context.mounted) return false;
      final devices =
          e.devices.isNotEmpty ? e.devices : await _fetchDevicesSafe(vpnService);
      if (!context.mounted) return false;
      final result = await showDeviceLimitModal(
        context,
        initialDevices: devices,
        maxDevices: authService.maxDevices,
      );
      if (!context.mounted) return false;
      if (result == DeviceLimitResult.loggedOutCurrentDevice) {
        await authService.logout();
        if (!context.mounted) return false;
        Navigator.pushNamedAndRemoveUntil(context, '/', (_) => false);
        return false;
      }
      if (result == DeviceLimitResult.resolved) {
        if (vpnService.isVpnSessionPotentiallyActive) {
          await vpnService.disconnect(source: 'device_limit_resolved_pre_retry');
        }
        vpnService.resetSession();
        await vpnService.clearXrayConfigCache();
        continue;
      }
      return false;
    } catch (e) {
      debugPrint('registerDeviceUntilOkWithModal: $e');
      if (regAttempts >= maxRegisterAttempts && context.mounted) {
        await _showRegisterExhaustedDialog(context);
      }
      return false;
    }
  }
  if (context.mounted) await _showRegisterExhaustedDialog(context);
  return false;
}

/// Результат connect use case: лимит устройств — модалка, при выходе с устройства полный logout.
Future<void> handleConnectDeviceLimitFromUseCase({
  required BuildContext context,
  required ConnectDeviceLimit result,
  required AuthService authService,
  required VpnService vpnService,
  required Future<ConnectResult> Function() onResolvedRetryConnect,
  void Function(ConnectResult retry)? onRetryCompleted,
}) async {
  final limitResult = await showDeviceLimitModal(
    context,
    initialDevices: result.devices,
    maxDevices: authService.maxDevices,
  );
  if (!context.mounted) return;

  if (limitResult == DeviceLimitResult.loggedOutCurrentDevice) {
    await authService.logout();
    if (!context.mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, '/', (_) => false);
    return;
  }

  if (limitResult == DeviceLimitResult.resolved) {
    final t = authService.token;
    if (t != null && t.isNotEmpty) {
      try {
        vpnService.resetSession();
        await vpnService.clearXrayConfigCache();
        await vpnService.ensureDeviceRegistered(t);
      } on DeviceLimitException catch (e) {
        authService.setPendingDeviceLimit(e);
        return;
      } catch (e) {
        debugPrint('handleConnectDeviceLimitFromUseCase: register after resolve: $e');
      }
    }
    final retry = await onResolvedRetryConnect();
    onRetryCompleted?.call(retry);
  }
}

/// Pending после авторизации: полный сброс VPN-сессии и кэша Xray, затем повторная регистрация устройства.
Future<void> handlePendingDeviceLimitAfterAuth({
  required BuildContext context,
  required AuthService authService,
  required VpnService vpnService,
}) async {
  if (!authService.hasPendingDeviceLimit) return;

  final devices = authService.pendingDeviceLimitDevices;
  final message = authService.pendingDeviceLimitMessage;
  authService.clearPendingDeviceLimit();

  final limitResult = await showDeviceLimitModal(
    context,
    initialDevices: devices,
    maxDevices: authService.maxDevices,
  );

  if (!context.mounted) return;

  if (limitResult == DeviceLimitResult.loggedOutCurrentDevice) {
    await authService.logout();
    if (!context.mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, '/', (_) => false);
    return;
  }

  if (limitResult == DeviceLimitResult.resolved) {
    final token = authService.token;
    if (token != null && token.isNotEmpty) {
      try {
        if (vpnService.isVpnSessionPotentiallyActive) {
          await vpnService.disconnect(source: 'device_limit_pending_after_auth');
        }
        vpnService.resetSession();
        await vpnService.clearXrayConfigCache();
        await vpnService.ensureDeviceRegistered(token);
      } catch (_) {}
    }
  } else {
    debugPrint(
      'DeviceLimitFlow: modal dismissed without action. Message: $message',
    );
  }
}

/// Регистрация устройства после успешного verify — **в фоне**, без блокировки [Navigator] на `/main`.
/// При [DeviceLimitException] выставляет [AuthService.setPendingDeviceLimit];
/// [PendingDeviceLimitListener] на главном shell покажет модалку лимита.
Future<void> registerDeviceAfterLoginBackground({
  required AuthService authService,
  required VpnService vpnService,
}) async {
  final token = authService.token;
  if (token == null || token.isEmpty) {
    debugPrint('[device-reg] skip: no token');
    return;
  }
  final sw = Stopwatch()..start();
  debugPrint('[device-reg] start');
  try {
    await vpnService.ensureDeviceRegistered(token);
    sw.stop();
    debugPrint('[device-reg] success total_ms=${sw.elapsedMilliseconds}');
  } on DeviceLimitException catch (e) {
    sw.stop();
    debugPrint('[device-reg] device_limit total_ms=${sw.elapsedMilliseconds}');
    authService.setPendingDeviceLimit(e);
  } catch (e, st) {
    sw.stop();
    debugPrint('[device-reg] error total_ms=${sw.elapsedMilliseconds} $e\n$st');
  }
}

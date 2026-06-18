import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../services/auth_service.dart';
import '../../services/native_vpn_service.dart';
import '../../services/vpn_service.dart';
import '../../core/logger/logger.dart';

/// Право на использование VPN: подписка, активный trial или нет доступа.
enum UserEntitlement {
  /// Нет подписки и trial исчерпан (или не авторизован — проверять isAuthenticated отдельно).
  none,
  trial,
  subscribed,
}

/// Единая точка: entitlement, целевой корневой маршрут, координация refresh при resume.
///
/// См. docs/MOBILE_APP_ROUTES_INVENTORY.md — канон `/main` vs `/trial-ended`.
class AppSessionController extends ChangeNotifier {
  AppSessionController(this._auth);

  final AuthService _auth;

  AuthService get auth => _auth;

  UserEntitlement get entitlement {
    if (_auth.hasActiveSubscription) return UserEntitlement.subscribed;
    if ((_auth.trialSecondsLeft ?? 0) > 0) return UserEntitlement.trial;
    return UserEntitlement.none;
  }

  /// Авторизован, но нет ни подписки, ни секунд trial.
  bool get needsPaywall =>
      _auth.isAuthenticated && entitlement == UserEntitlement.none;

  /// Целевой маршрут после входа / при согласованном состоянии с сервером.
  static String targetRouteForAuthenticatedUser(AuthService auth) {
    if (auth.hasActiveSubscription) return '/main';
    if ((auth.trialSecondsLeft ?? 0) > 0) return '/main';
    return '/trial-ended';
  }

  DateTime? _lastApiRefreshAfterResumeAt;
  // После resume не штурмуем control-plane: минимум 60с между burst refresh.
  static const _apiRefreshDebounce = Duration(seconds: 60);

  /// Возврат из фона: всегда нативный sync; burst запросов к API (статус + серверы) — с дебаунсом.
  Future<void> performResumeCoordination(VpnService vpnService) async {
    vpnService.onAppResumedFromBackground();
    await vpnService.syncConnectionStateWithNative();

    if (_auth.isAuthenticated) {
      // Не await: чтобы resume не ждал сетевой round-trip. Раньше бэкенд тянул Xray Stats по SSH (десятки сек);
      // теперь /vpn/status по умолчанию только БД — всё равно не await. connect() может кратко ждать только
      // если параллельно уже in-flight другой sync (см. VpnService._vpnStatusSyncInFlight).
      vpnService.syncConnectionStateWithServer(force: true).catchError((e) {
        Logger().debug('Синхронизация состояния с сервером при resume: $e',
            'AppSessionController');
      });
    }

    try {
      await const MethodChannel('com.granivpn.mobile/vpn')
          .invokeMethod<void>('requestQuickTileRefresh');
    } catch (_) {}

    if (!_auth.isAuthenticated) return;

    if (needsPaywall) {
      Logger().warning(
        'Доступ истёк при sync; VPN не отключаем без явного служебного stop-события',
        'AppSessionController',
      );
      try {
        await const MethodChannel('com.granivpn.mobile/vpn')
            .invokeMethod<void>('requestQuickTileRefresh');
      } catch (_) {}
      return;
    }

    final now = DateTime.now();
    final skipApiBurst = _lastApiRefreshAfterResumeAt != null &&
        now.difference(_lastApiRefreshAfterResumeAt!) < _apiRefreshDebounce;
    _lastApiRefreshAfterResumeAt = now;

    if (!skipApiBurst) {
      final needServers = vpnService.servers.isEmpty;
      if (needServers) {
        await vpnService.refreshControlPlaneSnapshot(_auth, force: true);
        Logger().info(
          'Control-plane snapshot загружен после возврата из фона',
          'AppSessionController',
        );
      } else {
        vpnService
            .refreshControlPlaneSnapshot(_auth)
            .catchError((e) => Logger().warning(
                  'Ошибка snapshot control-plane: $e',
                  'AppSessionController',
                ));
      }
      // Кардинальное сокращение шума: prewarm после resume отключён.
    }

    if (!_auth.isAuthenticated && vpnService.isVpnSessionPotentiallyActive) {
      Logger().warning(
        'Auth потеряна при sync, отключаем VPN',
        'AppSessionController',
      );
      try {
        await vpnService.disconnect(
          reason: VpnDisconnectReason.authLost,
          source: 'app_session_auth_lost',
        );
      } catch (_) {}
      try {
        await NativeVpnService.disconnectAmneziaWg(
          reason: 'auth_lost',
          source: 'app_session_auth_lost',
        );
      } catch (_) {}
      try {
        await NativeVpnService.disconnect(
          reason: 'auth_lost',
          source: 'app_session_auth_lost',
        );
      } catch (_) {}
    }
  }
}

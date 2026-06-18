import '../../core/vpn/vpn_connection_models.dart';
import '../../core/vpn_state_machine.dart';
import '../../l10n/app_localizations.dart';
import '../../services/vpn_service.dart';

/// Общая копирайтинг/UI-логика для [HomeScreen] и [TrialUnifiedScreen]
/// (один shell — [MainContentScreen], два варианта контента).
class VpnShellUiHelpers {
  VpnShellUiHelpers._();

  static String friendlyProgressMessage(String? raw, AppLocalizations l10n) {
    if (raw == null || raw.isEmpty) {
      return l10n.vpnProgressConnecting;
    }
    if (raw.contains('проверка разрешений')) {
      return l10n.vpnProgressVpnPermission;
    }
    if (raw.contains('проверка авторизации')) {
      return l10n.vpnProgressAuthCheck;
    }
    if (raw.contains('выбор сервера')) {
      return l10n.vpnProgressServerSelection;
    }
    if (raw.contains('регистрация устройства')) {
      return l10n.vpnProgressDeviceRegistration;
    }
    if (raw.contains('получение конфигурации')) {
      return l10n.vpnProgressConfigFetch;
    }
    if (raw.contains('обработка конфигурации')) {
      return l10n.vpnProgressConfigProcessing;
    }
    if (raw.contains('создание VPN интерфейса')) {
      return l10n.vpnProgressVpnInterface;
    }
    if (raw.contains('запуск протокола')) {
      return l10n.vpnProgressProtocolStart;
    }
    if (raw.contains('проверка трафика')) {
      return l10n.vpnProgressTrafficCheck;
    }
    if (raw.contains('подключено')) {
      return l10n.vpnProgressConnected;
    }
    return raw;
  }

  static String simpleProgressMessage(String? raw, AppLocalizations l10n) {
    if (raw == null || raw.isEmpty) return l10n.vpnProgressConnecting;
    final value = raw.toLowerCase();
    if (value.contains('проверяем доступ')) return l10n.vpnProgressAuthCheck;
    if (value.contains('выбираем оптимальный сервер')) {
      return l10n.vpnProgressServerSelection;
    }
    if (value.contains('регистрируем устройство')) {
      return l10n.vpnProgressDeviceRegistration;
    }
    if (value.contains('готовим защищенный профиль') ||
        value.contains('восстанавливаем защищенный профиль')) {
      return l10n.vpnProgressConfigFetch;
    }
    if (value.contains('проверяем параметры подключения')) {
      return l10n.vpnProgressConfigProcessing;
    }
    if (value.contains('создаем защищенный туннель')) {
      return l10n.vpnProgressVpnInterface;
    }
    if (value.contains('запускаем защищенный канал')) {
      return l10n.vpnProgressProtocolStart;
    }
    if (value.contains('проверяем защищенный трафик')) {
      return l10n.vpnProgressTrafficCheck;
    }
    if (value.contains('соединение установлено')) {
      return l10n.vpnProgressConnected;
    }
    if (value.contains('завершаем защищ')) {
      return l10n.homeDisconnectingSubtitle;
    }
    if (value.contains('отменяем подключение')) {
      return l10n.vpnProgressConnectCancelling;
    }
    if (value.contains('пробуем другой маршрут')) return l10n.vpnRetryRouteWarm;
    if (value.contains('пробуем оптимизировать маршрут')) {
      return l10n.vpnOptimizeRoute;
    }
    if (value.contains('соединение может занять')) {
      return l10n.vpnSlowNetworkWarm;
    }
    if (value.contains('восстановление связи занимает')) {
      return l10n.vpnConnectPatienceWarm;
    }
    if (value.contains('первичная настройка на медленной сети')) {
      return l10n.vpnConnectPatienceCold;
    }
    if (value.contains('это нормально при медленной сети')) {
      return l10n.vpnSlowNetworkCold;
    }
    return raw;
  }

  static String? simpleConnectionBadge(String? raw, AppLocalizations l10n) {
    if (raw == null || raw.isEmpty) return null;
    final value = raw.toLowerCase();
    if (value.contains('быстрое восстановление')) {
      return l10n.vpnBadgeFastReconnect;
    }
    if (value.contains('первичная настройка')) return l10n.vpnBadgeFirstSetup;
    return raw;
  }

  static String? connectionFlowBadge(
      VpnService vpnService, AppLocalizations l10n) {
    final uiState = vpnService.vpnUiSessionState;
    if (uiState != VpnUiSessionState.connecting &&
        uiState != VpnUiSessionState.reconnecting &&
        uiState != VpnUiSessionState.connectedWarm) {
      return null;
    }
    switch (vpnService.connectionFlowType) {
      case ConnectionFlowType.warmCacheReconnect:
        return l10n.vpnBadgeFastReconnect;
      case ConnectionFlowType.coldCreateConfig:
        return l10n.vpnBadgeFirstSetup;
      case ConnectionFlowType.unknown:
        return null;
    }
  }

  /// [waitTrafficHintWhenConnected] — для trial: пока нет трафика после connect, отдельный подзаголовок.
  static String connectingSubtitle(
    VpnService vpnService,
    AppLocalizations l10n, {
    bool waitTrafficHintWhenConnected = false,
  }) {
    if (waitTrafficHintWhenConnected &&
        vpnService.isConnected &&
        !vpnService.hasEverSeenTraffic) {
      return l10n.vpnWaitSecureTraffic;
    }

    final base =
        friendlyProgressMessage(vpnService.connectionProgress?.message, l10n);
    final startedAt = vpnService.connectionAttemptStartedAt;
    if (startedAt == null) return base;

    final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
    final flow = vpnService.connectionFlowType;
    final warm = flow == ConnectionFlowType.warmCacheReconnect;

    if (warm) {
      if (elapsedMs >= 8000) return l10n.vpnConnectPatienceWarm;
      if (elapsedMs >= 5000) return l10n.vpnRetryRouteWarm;
      if (elapsedMs >= 3000) return l10n.vpnSlowNetworkWarm;
    } else {
      if (elapsedMs >= 10000) return l10n.vpnConnectPatienceCold;
      if (elapsedMs >= 6000) return l10n.vpnOptimizeRoute;
      if (elapsedMs >= 3000) return l10n.vpnSlowNetworkCold;
    }
    return base;
  }
}

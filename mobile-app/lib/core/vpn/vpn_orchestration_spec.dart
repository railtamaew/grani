/// Спецификация оркестрации VPN (константы и контракты). Источник правды для COMMIT / VERIFY / fail-fast.
///
/// **Исключение restore/sync:** переход в `connected` без повторного app-layer VERIFY
/// допускается, когда туннель уже поднят нативно и состояние синхронизируется из
/// `VpnService.syncConnectionStateWithNative` / `VpnService._restoreConnectionStateFromNative`.
/// Не добавлять полный VERIFY в эти пути без обновления контракта (см. docs/STAGE_2_NETWORK_CONTRACT.md).
///
/// **Hedged GET** (см. `ApiClient`) — не является частью sequential fallback
/// (primary → fallback → STOP); это отдельная политика только для critical idempotent GET.
/// Подробности: docs/STAGE_2_NETWORK_CONTRACT.md.
library;

import 'package:flutter/foundation.dart';

/// Плоскости control-plane HTTP (см. план: bootstrap / auth / logging / vpn_control).
enum ControlPlanePlane {
  bootstrap,
  auth,
  logging,
  vpnControl,
}

/// Владение сетью в смысле приоритета бюджета (plan: CONNECTING → vpn_plane).
enum NetworkOwnership {
  /// Только оркестратор VPN / служебные запросы этапа подключения.
  vpnPlane,

  /// Разделение по приоритетам (после COMMIT).
  sharedBudget,

  /// Фон / пауза — минимум HTTP.
  restricted,
}

/// Подсказка маршрута для Policy Engine (детерминированный выбор клиента).
enum NetworkRouteHint {
  direct,
  tunnel,
  transitional,
}

/// Критерии VERIFY (COMMIT разрешён только после успешной проверки).
/// Реализация проверки — в [VpnService._connectStageVerify] / [_verifyConnection].
@immutable
class TunnelVerifyCriteria {
  const TunnelVerifyCriteria({
    this.requireTrafficOrIpCheck = true,
    this.maxVerifyWallClock = const Duration(seconds: 6),
  });

  final bool requireTrafficOrIpCheck;
  final Duration maxVerifyWallClock;

  static const TunnelVerifyCriteria productionDefaults = TunnelVerifyCriteria();
}

/// Верхнеуровневые таймауты транзакции CONNECT (fail-fast).
@immutable
class VpnOrchestrationSpec {
  const VpnOrchestrationSpec._();

  /// Wall-clock для prereq этапа (permissions/device/network/token/server select).
  static const Duration connectingPrerequisitesWallClock = Duration(seconds: 16);

  /// Wall-clock для fetch конфигурации на control-plane.
  static const Duration connectingGetConfigWallClock = Duration(seconds: 45);

  /// Wall-clock для apply/verify.
  /// Для Xray сюда входит session/prepare (в _connectXray внутри apply_protocol), поэтому окно больше.
  static const Duration connectingApplyVerifyWallClock = Duration(seconds: 55);

  /// Legacy aggregate timeout kept for compatibility (not primary in new stage-aware flow).
  static const Duration connectingWallClock = Duration(seconds: 32);

  /// Порог «слишком долго» для метрик / логов (не обязательно равен wall-clock).
  static const Duration connectingFailFastWarning = Duration(seconds: 45);

  /// Максимум одновременных control-plane HTTP (после политики; второй предел поверх Dio-gate в CPC).
  /// Раньше 3 — при всплеске после OAuth (prewarm session/prepare + /auth/me + refreshServers)
  /// четвёртый запрос ловил [ControlPlaneDeniedException('budget')]. Пять слотов остаются консервативными.
  static const int maxConcurrentControlPlaneHttp = 5;
}

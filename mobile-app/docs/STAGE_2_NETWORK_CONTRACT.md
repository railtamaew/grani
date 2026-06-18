# Stage 2 — сетевой контракт (инварианты и исключения)

Источник правды для ревью: что **нельзя «чинить»** без обновления этого документа.

См. также: [METRICS_AND_OBSERVABILITY.md](METRICS_AND_OBSERVABILITY.md) (раздел Stage 2.5).

**Пост-логин UI (device limit и аналоги):** критические ошибки, которые должны довести пользователя до отдельного экрана/модалки после входа, нужно отражать через **реакцию на состояние** (например `ChangeNotifier` + listener у корня shell), а не через **однократную** проверку при mount экрана: фоновые шаги (регистрация устройства и т.д.) могут завершиться позже, чем первый кадр главного экрана.

## Инварианты Stage 2

1. **Control Plane Client (CPC)** — единая точка HTTP к API для control plane: [`ControlPlaneClient`](../lib/core/vpn/control_plane_client.dart). Произвольный `Dio` вне CPC для этого трафика запрещён.
2. **VERIFY до COMMIT** — на **новом** пользовательском connect туннель не считается установленным, пока не пройден [`_connectStageVerify`](../lib/services/vpn_service.dart) / [`_verifyConnection`](../lib/services/vpn_service.dart) (обязательный TCP probe и т.д.).
3. **Sequential fallback** — на один логический запрос не более **двух** базовых URL (primary + fallback): [`PreferredRouteStorage.maxApiBaseAttemptsPerRequest`](../lib/core/api/preferred_route_storage.dart).

---

## EXCEPTION — Restore / sync с нативным VPN

**Допускается** переход приложения в состояние «подключено» (`connected`) **без** повторного app-layer VERIFY, если:

- нативный VPN уже поднят (источник истины — [`GraniVpnService.isVpnRunning`](../android/app/src/main/kotlin/com/granivpn/mobile/VpnService.kt) / [`NativeVpnService.getStatus`](../lib/services/native_vpn_service.dart));
- синхронизация идёт через [`VpnService._restoreConnectionStateFromNative`](../lib/services/vpn_service.dart) или [`VpnService.syncConnectionStateWithNative`](../lib/services/vpn_service.dart).

**Обоснование:** повторный полный VERIFY при каждом cold start / возврате в приложение повышает риск ложных отказов и **reconnect storm** (лишние disconnect/reconnect).

**Не делать:** не добавлять автоматический полный VERIFY в эти пути «ради соответствия документу» без отдельного RFC.

**Опциональная будущая политика (не обязана быть в коде):** *lazy verify* при первом значимом сетевом событии или при первом пользовательском запросе через туннель — только если понадобится усилить гарантии. На момент фиксации контракта отдельной реализации lazy verify может не быть.

---

## HEDGED REQUEST POLICY

**Hedged** — это **не** замена sequential `primary → fallback → STOP`. Это отдельная стратегия только для узкого класса запросов.

Разрешено **только** если одновременно:

- путь помечен как critical control: [`PreferredRouteStorage.isCriticalControlPath`](../lib/core/api/preferred_route_storage.dart);
- включён флаг [`AppConfig.enableHedgedCriticalGet`](../lib/config/app_config.dart);
- метод **GET**;
- операция **идемпотентная** (чтение без побочных эффектов на сервере).

Реализация: [`ApiClient._tryHedgedGetCritical`](../lib/core/api/api_client.dart) — максимум **два** параллельных исходящих запроса (индексы баз 0 и 1), побеждает первый успешный ответ.

Общий лимит параллелизма и gate запросов — через [`ControlPlaneClient`](../lib/core/vpn/control_plane_client.dart) (`_ApiConcurrencyGate` и интерцепторы).

**Запрет:** не распространять hedged на POST/PUT/DELETE, не-критичные пути и не-idempotent GET без ревью и обновления этого документа.

---

## Stage 2.5 — stabilization

См. [METRICS_AND_OBSERVABILITY.md](METRICS_AND_OBSERVABILITY.md) (раздел «Stage 2.5 — stabilization»): метрики connect/verify, логирование state/plane/route, чеклист edge-case.

## Что намеренно не входит в этот PR

- Реализация lazy verify в коде (только политика выше).
- Stage 3 (оптимизации производительности) до стабилизации наблюдаемости в проде.

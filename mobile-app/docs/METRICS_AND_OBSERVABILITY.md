# Метрики и наблюдаемость

## PerfLogger — метрики старта

В [lib/core/perf/perf_logger.dart](lib/core/perf/perf_logger.dart) замеряются этапы запуска приложения:

| Метрика | Описание |
|---------|----------|
| app_startup | Общее время от старта до первого кадра (останавливается в addPostFrameCallback). |
| app_config_init | Инициализация AppConfig (загрузка версии из package_info). |
| core_init | Инициализация StorageService, CacheService, ApiClient (один SharedPreferences, параллельно Storage + Cache). |
| auth_init | Создание AuthService и ожидание загрузки токенов. |
| route_determination | Определение начального маршрута (по кэшу, без блокировки на refreshUserStatus). |

Где смотреть: в debug-сборке логи выводятся через Logger (уровень info) с префиксом `Perf[...]`. В release при интеграции с бэкендом/аналитикой эти метрики можно добавлять в payload (например, перцентили времени до первого экрана).

## Этапы подключения VPN (VpnService)

Этапы подключения логируются через `_logConnectionStage` и ConnectionLogger. Основные этапы:

- permissions, device_and_network, token_and_sync, select_server, get_config, apply_protocol, verify, local_disconnect.

При ошибке или таймауте в логах (debug) видно этап и протокол. Для production при необходимости можно формализовать события (например, `connect_stage_get_config`, `connect_stage_apply_protocol`) и отправлять краткий контекст (этап, протокол, код ошибки) без персональных данных.

## Системный аудит и runbook (8 слоёв)

- Архитектура источников истины и сценарии: [docs/audit/SYSTEM_AUDIT_8_LAYER.md](audit/SYSTEM_AUDIT_8_LAYER.md).
- Сбор logcat, корреляция `connection_session_id`, алерты: [docs/audit/OBSERVABILITY_RUNBOOK.md](audit/OBSERVABILITY_RUNBOOK.md).

## Logger

- Уровни: debug, info, warning, error.
- В release минимальный уровень — info; debug-записи не выводятся и не хранятся в буфере.
- Буфер в памяти: до 1000 записей в debug, до 100 в release (только info и выше).
- Экспорт: `Logger().exportLogs()` для отправки логов на сервер.

## Stage 2.5 — stabilization

Цель: **наблюдаемость** сетевого слоя и VPN после внедрения Stage 2, до перехода к Stage 3 (оптимизации). Контракт исключений Stage 2: [STAGE_2_NETWORK_CONTRACT.md](STAGE_2_NETWORK_CONTRACT.md).

### Метрики (целевые имена для прод / аналитики)

| Метрика | Назначение | Источник в коде (сейчас / доработка) |
|---------|------------|--------------------------------------|
| `connect_success_rate` | Доля успешных завершений connect-транзакции | Агрегация по событиям успеха/ошибки в `VpnService` (см. `_logConnectionTimingSummary`, логи этапов). |
| `verify_fail_rate` | Доля неуспешных VERIFY (TCP probe / таймаут `vpn_verify`) | Логи `verify_connection`, исключения `TimeoutException('vpn_verify')`, `_disconnectAfterVerifyFailure`. |
| `connect_time_p95` | Перцентиль времени от тапа до `connected` | Поля `_lastConnectionTimingMs` / `tap_to_connected_ms`, префикс логов `[xray-timing]`. |

Интеграция в бэкенд или Firebase — по мере готовности; на этапе 2.5 достаточно формализовать имена и точки съёма.

### Логирование: state + plane + route

- **State machine VPN:** этапы в `VpnService` (`_logConnectionStage`, `ConnectionProgress`), корреляция через `connection_session_id` в ConnectionLogger.
- **Control plane plane:** `ControlPlanePlane` / `ControlPlanePlaneResolver` при запросах через `ControlPlaneClient`.
- **Route / base URL:** при `AppConfig.enableRouteVerboseLogs` — подробные логи маршрута в `ApiClient` (`route_policy`, `route_selected`); без секретов и тел токенов.

### Чеклист edge-case (ручной / полевой)

- **Restore:** приложение закрыто, VPN включён, повторное открытие — интернет и UI не в противоречии с нативным статусом (см. EXCEPTION в контракте).
- **VERIFY:** не завышать строгость без метрик `verify_fail_rate` на реальных сетях; ложные отказы снимать по данным, а не «на глаз».

Эти проверки не блокируют релиз, но обязательны перед расширением Stage 3.

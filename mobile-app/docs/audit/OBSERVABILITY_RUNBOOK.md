# Runbook: наблюдаемость VPN-клиента (end-to-end)

## Цель

Собрать **одну воспроизводимую цепочку** от тапа «Подключить» до нативного туннеля и API при инцидентах «не воспроизводится».

## Корреляция (уже в коде)

| Слой | Маркер | Где смотреть |
|------|--------|----------------|
| Dart → бэкенд | `connection_session_id`, `connection_flow_type`, `trigger` | `ConnectionLogger` → `/vpn/logs/send`, debug при flush |
| Android | `[CORRELATION] connection_session_id=… start_source=…` | `adb logcat` / `GraniVpnService` |
| TUN / имя VPN-сессии | `[CORRELATION] xray_tun_session=… full_connection_session_id=…` — имя сессии Android VPN + полный id | `GraniVpnService` перед стартом Xray |
| Handover | `[NET_MONITOR] network_change …` + тот же `connection_session_id` в Intent | `GraniVpnService` |

## Фильтры logcat (пример)

```bash
adb logcat -s GraniVpnService:V VpnPlugin:V XrayNativeWrapper:V GoLog:V *:S
```

Дополнительно grep по процессу приложения:

```bash
adb logcat | grep -E 'CORRELATION|NET_MONITOR|start_source|connection_session'
```

## Flutter / debug

- Включить при необходимости `AppConfig.enableRouteVerboseLogs` — подробные строки `PreferredRouteStorage` и `ApiClient`.
- Экспорт внутренних логов: `Logger().exportLogs()` (см. [`METRICS_AND_OBSERVABILITY.md`](../METRICS_AND_OBSERVABILITY.md)).

## Метрики (ориентиры для бэкенда/аналитики)

Из событий `ConnectionLogger` и таймингов `VpnService`:

| Метрика | Поле / источник |
|---------|-----------------|
| Время tap → connected | `connection_duration_ms` в `connection_success`, `_lastConnectionTimingMs['tap_to_connected_ms']` |
| Холодный vs тёплый путь | `connection_flow_type` |
| Этапы | `event_type: connection_stage`, `error_details.stage` |
| Ошибка маршрута API | `api_route_used` в деталях лога (после успешного ответа) |

## Алерты (рекомендация для бэкенда)

- Всплеск `connection_error` / `protocol_error` с одним `device_id` за короткий интервал.
- Рост доли `coldCreateConfig` при стабильной сети (возможна деградация кэша или API).

## Минимальный пакет для разработчика

1. Время инцидента (UTC) и версия приложения (`app_version` в логах).
2. Фрагмент logcat с `CORRELATION` и `NET_MONITOR` за ±2 минуты.
3. Экспорт клиентских логов или подтверждение доставки `/vpn/logs/send` (если доступно в админке).

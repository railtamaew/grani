# API-контракт Admin Observability (v1)

## Назначение

Предоставить стабильные API-контракты для нового observability-модуля в админке.

## Аутентификация

- Та же RBAC-модель админки, что и у существующих `/api/admin/*`.
- Роли только для чтения могут просматривать, но не изменять инциденты.

## Базовый префикс

- `/api/admin/observability`

## Endpoints

### 1) Запрос нормализованных событий

`GET /api/admin/observability/events`

Параметры запроса:

- `from` (ISO datetime, required)
- `to` (ISO datetime, required)
- `limit` (default 200, max 2000)
- `cursor` (optional)
- `user_id`, `device_id`, `server_id`
- `vpn_session_id`, `request_id`, `trace_id`
- `event_name`, `severity`, `protocol`, `reason_code`
- `detail_level` (`basic|enriched`, по умолчанию `basic`)
- `correlation_window_seconds` (для `enriched`, по умолчанию 120; диапазон 30..3600)

Ответ:

```json
{
  "items": [
    {
      "event_time": "2026-04-27T08:00:00.123Z",
      "event_name": "VPN_TUNNEL_ESTABLISHED",
      "severity": "info",
      "vpn_session_id": "sess_abc",
      "user_id": 123,
      "device_id": 456,
      "server_id": 10,
      "message": "Tunnel established",
      "reason_code": null,
      "attrs": {}
    }
  ],
  "next_cursor": "...",
  "prev_cursor": "...",
  "detail_level": "basic",
  "analytics_backend": "postgres"
}
```

Пояснения:

- `basic`: быстрый ответ, только базовые поля события (рекомендуется для live-ленты).
- `enriched`: добавляет `user_context`, `device_context`, `server_context` и `related_logs` с near-event корреляцией по времени.

### 2) Путь пользователя (User Journey)

`GET /api/admin/observability/users/{user_id}/journey`

Параметры запроса:

- `from`, `to` (required)
- `server_id` (optional)
- `include_raw` (default false)

Ответ:

- Упорядоченный таймлайн, сгруппированный по `vpn_session_id`.
- Включает человекочитаемые названия и подсказки из словаря событий.

### 3) Конфликты сервера

`GET /api/admin/observability/servers/{server_id}/conflicts`

Параметры запроса:

- `from`, `to`
- `include_resolved` (default false)

Ответ:

- Снимки активных конфликтов:
  - duplicate sessions
  - stale tunnels
  - config drifts

### 4) Список инцидентов

`GET /api/admin/observability/incidents`

Параметры запроса:

- `status`, `severity`, `incident_type`
- `from`, `to`
- `server_id`, `user_id`
- `limit`, `cursor`

### 5) Детали инцидента

`GET /api/admin/observability/incidents/{incident_id}`

Включает:

- метаданные инцидента
- evidence
- фрагменты связанных событий
- комментарии/действия операторов

### 6) Действия с инцидентом

- `POST /api/admin/observability/incidents/{incident_id}/assign`
- `POST /api/admin/observability/incidents/{incident_id}/comment`
- `POST /api/admin/observability/incidents/{incident_id}/status`

Переходы состояний:

- `open -> investigating -> mitigated -> resolved`
- `open|investigating -> ignored`

### 7) Словарь событий

- `GET /api/admin/observability/dictionary/events`
- `PUT /api/admin/observability/dictionary/events/{event_name}`

Используется для управления отображаемыми названиями и шаблонами комментариев.

## Страницы UI, которые работают через API

- `Live Event Stream`
- `User Journey`
- `Server Conflicts`
- `Incident Center`
- `Incident Detail`

## Совместимость

- Существующие endpoints `/api/admin/logs/*` и `/api/admin/users/{id}/diagnostics` остаются активными на время миграции.
- Новый UI использует observability endpoints как приоритетные; fallback на legacy только при недоступности.

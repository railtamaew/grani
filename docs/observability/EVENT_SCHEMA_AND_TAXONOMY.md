# Схема и таксономия событий (Observability V2)

## Цели

- Стандартизировать все observability-события в единую схему.
- Сделать события читаемыми для людей и машинно-обрабатываемыми для правил.
- Обеспечить корреляцию между backend, VPN-нодами, мобильными клиентами и действиями операторов.

## Каноническая схема событий (v1)

Все нормализованные события в ClickHouse ДОЛЖНЫ содержать:

- `event_time` (DateTime64): timestamp события в UTC.
- `event_name` (String): стабильное семантическое имя (см. таксономию).
- `severity` (LowCardinality(String)): `debug|info|warn|error|critical`.
- `source` (LowCardinality(String)): `backend|client|vpn_node|worker|admin_panel`.
- `request_id` (Nullable(String))
- `trace_id` (Nullable(String))
- `span_id` (Nullable(String))
- `vpn_session_id` (Nullable(String))
- `user_id` (Nullable(UInt64))
- `device_id` (Nullable(UInt64))
- `device_fingerprint` (Nullable(String))
- `server_id` (Nullable(UInt64))
- `protocol` (Nullable(LowCardinality(String)))
- `stage` (Nullable(LowCardinality(String)))
- `outcome` (Nullable(LowCardinality(String))) - `success|failure|retry|timeout|partial`.
- `reason_code` (Nullable(String)) - нормализованный короткий код причины.
- `message` (Nullable(String)) - короткое описание, ориентированное на человека.
- `config_revision` (Nullable(String))
- `config_hash_expected` (Nullable(String))
- `config_hash_actual` (Nullable(String))
- `attrs_json` (String) - дополнительный payload в JSON.
- `schema_version` (UInt16), по умолчанию 1.

## Правила ingestion

- Payload от источников преобразуется в каноническую схему ingestion-пайплайном.
- Неизвестные поля перемещаются в `attrs_json`.
- Чувствительные значения (ключи, секреты, токены) маскируются до сохранения.
- Имена событий неизменяемы после релиза; для депрекации нужна alias-маппинга.

## Базовая таксономия

## 1) Жизненный цикл сессии

- `VPN_CONNECT_REQUESTED`
- `VPN_CONNECT_PREPARE_STARTED`
- `VPN_CONNECT_PREPARE_FINISHED`
- `VPN_CONFIG_APPLY_QUEUED`
- `VPN_CONFIG_APPLY_STARTED`
- `VPN_CONFIG_APPLY_FINISHED`
- `VPN_TUNNEL_ESTABLISHED`
- `VPN_TUNNEL_TRAFFIC_FIRST_SEEN`
- `VPN_DISCONNECT_REQUESTED`
- `VPN_TUNNEL_CLOSED`

## 2) Конфликты и целостность

- `VPN_SESSION_DUPLICATE_DETECTED`
- `VPN_SESSION_STALE_DETECTED`
- `VPN_CONFIG_CONFLICT_DETECTED`
- `VPN_CONFIG_REVISION_MISMATCH`
- `VPN_DEVICE_REBIND_DETECTED`

## 3) Здоровье ноды и протокола

- `VPN_NODE_HEARTBEAT_OK`
- `VPN_NODE_HEARTBEAT_MISSED`
- `VPN_XRAY_RELOAD_FAILED`
- `VPN_WIREGUARD_RELOAD_FAILED`
- `VPN_PROTOCOL_HANDSHAKE_FAILED`

## 4) Качество клиентского соединения

- `VPN_CLIENT_CONNECTION_ERROR`
- `VPN_CLIENT_RECONNECT_STORM`
- `VPN_CLIENT_NETWORK_CHANGED`
- `VPN_CLIENT_APP_STATE_CHANGED`

## 5) Операторский workflow

- `OBS_INCIDENT_CREATED`
- `OBS_INCIDENT_UPDATED`
- `OBS_INCIDENT_RESOLVED`
- `OBS_COMMENT_ADDED`

## Примеры Reason Code

- `DUP_ACTIVE_SESSION`
- `STALE_TUNNEL_NO_HEARTBEAT`
- `CONFIG_HASH_MISMATCH`
- `CLIENT_HELLO_REALITY_MISMATCH`
- `DEVICE_ID_REASSIGNED`
- `CONNECTIVITY_TIMEOUT`

## Человекочитаемый словарь событий

Таблица `event_dictionary` в PostgreSQL хранит:

- `event_name`
- `display_name_ru`
- `display_name_en`
- `default_comment_template`
- `operator_hint`
- `severity_default`
- `is_active`

Админка должна использовать этот словарь для человекочитаемого отображения и подсказок.

## Минимальный DDL ClickHouse (справочно)

```sql
CREATE TABLE observability_events_v1
(
  event_time DateTime64(3, 'UTC'),
  event_name String,
  severity LowCardinality(String),
  source LowCardinality(String),
  request_id Nullable(String),
  trace_id Nullable(String),
  span_id Nullable(String),
  vpn_session_id Nullable(String),
  user_id Nullable(UInt64),
  device_id Nullable(UInt64),
  device_fingerprint Nullable(String),
  server_id Nullable(UInt64),
  protocol Nullable(LowCardinality(String)),
  stage Nullable(LowCardinality(String)),
  outcome Nullable(LowCardinality(String)),
  reason_code Nullable(String),
  message Nullable(String),
  config_revision Nullable(String),
  config_hash_expected Nullable(String),
  config_hash_actual Nullable(String),
  attrs_json String,
  schema_version UInt16
)
ENGINE = MergeTree
PARTITION BY toDate(event_time)
ORDER BY (event_time, event_name, server_id, user_id, device_id, vpn_session_id);
```

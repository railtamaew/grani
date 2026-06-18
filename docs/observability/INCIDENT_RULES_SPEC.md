# Спецификация правил инцидентов (Observability V2)

## Назначение

Определить детерминированные правила, которые преобразуют нормализованные события в инциденты для операторов.

## Серьезность инцидентов

- `P1`: крупная авария или системная регрессия.
- `P2`: значимое влияние на пользователей; частичная деградация сервиса.
- `P3`: локальная проблема пользователя/устройства/сервера.
- `P4`: информационная аномалия.

## Входы rule engine

- Нормализованные события в ClickHouse (`observability_events_v1`).
- Состояние в Postgres (`users`, `devices`, `servers`, активные подписки).
- Опциональное runtime-состояние (назначение edge, снимки здоровья серверов).

## Контракт выхода правил

- `incident_key` (ключ дедупликации)
- `incident_type`
- `severity`
- `status` (`open|investigating|mitigated|resolved|ignored`)
- `title`
- `summary`
- `evidence_json`
- `affected_user_count`
- `affected_device_count`
- `affected_server_count`

## Базовые правила

### R1 Дубли активных сессий

- Триггер:
  - >=2 событий `VPN_TUNNEL_ESTABLISHED` для одной пары `(user_id, device_fingerprint)` в течение 10 минут
  - без соответствующего `VPN_TUNNEL_CLOSED`.
- Серьезность:
  - P2, если >=20 затронутых пользователей за 15 минут, иначе P3.
- Тип инцидента:
  - `duplicate_session`.

### R2 Stale-туннель

- Триггер:
  - есть `VPN_TUNNEL_ESTABLISHED` и нет heartbeat/трафика > N минут (настраиваемо, по умолчанию 15)
  - при этом backend все еще помечает сессию/устройство как активные.
- Серьезность:
  - P3 (эскалация до P2 при кластерном всплеске).
- Тип инцидента:
  - `stale_tunnel`.

### R3 Дрифт/конфликт конфигурации

- Триггер:
  - `VPN_CONFIG_APPLY_FINISHED` с несовпадением expected/actual hash или revision, либо
  - повторяющиеся `VPN_CONFIG_REVISION_MISMATCH`.
- Серьезность:
  - P2; P1 если затронуто >3 серверов.
- Тип инцидента:
  - `config_conflict`.

### R4 Частая перепривязка устройства

- Триггер:
  - множественные `VPN_DEVICE_REBIND_DETECTED` для одного `device_fingerprint` между разными `user_id` за короткий период.
- Серьезность:
  - P3.
- Тип инцидента:
  - `device_identity_conflict`.

### R5 Шторм переподключений

- Триггер:
  - повторяющийся цикл `VPN_CLIENT_CONNECTION_ERROR` + `VPN_CONNECT_REQUESTED` >=K раз за 5 минут для одного `vpn_session_id` или устройства.
- Серьезность:
  - P2 для больших групп, P3 для единичного пользователя.
- Тип инцидента:
  - `reconnect_storm`.

## Группировка и дедупликация

- Формат ключа дедупликации:
  - `incident_type:scope:bucket`
- Примеры scope:
  - уровень сервера: `server:{server_id}`
  - уровень пользователя: `user:{user_id}`
  - глобальный: `global`
- Временной bucket:
  - 15 минут по умолчанию.

## Авторазрешение

- Инцидент автоматически закрывается, если нет новых совпадающих событий в окне охлаждения:
  - P1/P2: 30 минут
  - P3/P4: 15 минут

## Таблицы Postgres (справочно)

```sql
CREATE TABLE observability_incidents (
  id BIGSERIAL PRIMARY KEY,
  incident_key TEXT NOT NULL,
  incident_type TEXT NOT NULL,
  severity TEXT NOT NULL,
  status TEXT NOT NULL,
  title TEXT NOT NULL,
  summary TEXT,
  evidence_json JSONB NOT NULL DEFAULT '{}'::jsonb,
  first_seen_at TIMESTAMPTZ NOT NULL,
  last_seen_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX ux_observability_incidents_key_status
ON observability_incidents (incident_key, status)
WHERE status IN ('open', 'investigating', 'mitigated');
```

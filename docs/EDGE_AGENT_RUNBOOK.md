# Edge-агент: runbook для выката и саппорта

Контракт и архитектура: [EDGE_AGENT_SKETCH.md](./EDGE_AGENT_SKETCH.md). Скрипты на ноде: [scripts/edge-node/README.md](../scripts/edge-node/README.md).

## 1. Чеклист выката API (БД)

1. Применить миграции **в указанном порядке**:
   - `backend/migrations/add_edge_agent_server_columns.sql`
   - `backend/migrations/add_edge_node_assignments_table.sql`
2. Выкатить версию бэкенда с роутером `/api/internal/node/v1` и Celery-воркером, который обрабатывает `vpn.apply_xray_config`.
3. Убедиться, что с нод до API открыт **исходящий** HTTPS (без обязательного SSH с панели на ноду для рутины).

## 2. Чеклист одной ноды

1. Сгенерировать секрет, положить **hex SHA-256** в `servers.edge_agent_token_hash`, совпадающий с секретом на ноде (см. README в `scripts/edge-node/`).
2. Установить **heartbeat** (`grani-edge-heartbeat.timer`) — иначе не будет `edge_last_heartbeat_at` и сложнее диагностика.
3. Установить **poll** (`poll-and-apply.sh` по таймеру) — без него задания `apply_xray_config` остаются в `pending` / `dispatched`.
4. В `/etc/default/grani-edge`: корректные `GRANI_API_BASE`, `GRANI_NODE_ID` (= `servers.id`), путь к токену, `GRANI_XRAY_CONFIG`, при необходимости `GRANI_XRAY_SYSTEMD_UNIT`.

## 3. Быстрая проверка с ноды

Подставьте свой URL и токен (как в конфиге агента):

```bash
curl -sS -X POST "$GRANI_API_BASE/api/internal/node/v1/heartbeat" \
  -H "Authorization: Bearer $(cat /etc/grani-edge/token)" \
  -H "Content-Type: application/json" \
  -d "{\"node_id\":$GRANI_NODE_ID,\"config_hash\":\"noop\",\"xray_running\":true,\"agent_version\":\"1\"}"

curl -sS -G "$GRANI_API_BASE/api/internal/node/v1/assignment" \
  -H "Authorization: Bearer $(cat /etc/grani-edge/token)" \
  --data-urlencode "node_id=$GRANI_NODE_ID"
```

Ожидание: `401` — неверный токен или не задан `edge_agent_token_hash` для этого `servers.id`; `200` с пустым `assignment` — норма, если очередь пуста.

## 4. Логи на API (мониторинг)

Искать в логах приложения префиксы: `[edge_agent_heartbeat]`, `[edge_agent_assignment]`, `[edge_enqueue]`.

Идеи для алертов: нет обновления `edge_last_heartbeat_at` дольше N минут для серверов с токеном; рост `pending` / залипших `dispatched`; частые неуспешные `action=result`.

## 5. SQL для операторов

Файл [edge_agent_ops_queries.sql](./edge_agent_ops_queries.sql) — срезы по heartbeat, статусам заданий, pending/dispatched, ошибкам.

## 5.1 Авто-алерты (SQL + Telegram)

Для быстрого production-контроля добавлен скрипт:
`backend/scripts/ops/edge_alerts_check.py`

Что проверяет:
- heartbeat stale/missing;
- backlog по `pending`/`dispatched`;
- новые `failed` assignment.

Базовый запуск:

```bash
cd /opt/grani/backend
python3 scripts/ops/edge_alerts_check.py --dry-run --verbose
```

Env:
- `DATABASE_URL` (обязательно)
- `TELEGRAM_BOT_TOKEN` и `TELEGRAM_CHAT_ID` (для доставки)
- пороги: `EDGE_ALERT_HEARTBEAT_STALE_SEC`, `EDGE_ALERT_PENDING_STALE_SEC`, `EDGE_ALERT_DISPATCHED_STALE_SEC`, `EDGE_ALERT_FAILED_WINDOW_SEC`

Коды выхода:
- `0` — проблем нет
- `1` — активные алерты
- `2` — runtime ошибка

Готовые примеры cron/systemd: `backend/scripts/ops/README.md`.

## 6. Типовые проблемы

- Конфиг не обновляется: таймер poll, совпадение `node_id`/токена с БД, таблица `edge_node_assignments`, логи `[edge_enqueue]`.
- `401`: хеш в БД от plaintext токена; не перепутан `servers.id`.
- Xray старый при отключённом SSH: reload должен сделать агент — смотреть `poll-and-apply.sh` и journal.
- Задание с ошибкой: поле `result_message` в БД; права на конфиг и `systemctl`.

## 7. Fallback по SSH

При `edge_agent_token_hash` конфиг уходит в очередь агента. Автоматической добивки по SSH при сбое агента может не быть — отдельное решение (ручной SSH, задача в бэклоге, временное снятие токена).

# Edge-агент вместо «чистого SSH» при масштабировании нод

## Проблема

Текущая модель: бэкенд по SSH выполняет команды на VPN-нодах (обновление конфигов Xray, reload и т.д.). При росте числа нод и частоты операций это даёт:

- узкое место по количеству одновременных SSH-сессий и ретраям;
- сложность с firewall/NAT и ключами;
- слабую наблюдаемость (успех команды ≠ успешный reload сервиса).

## Направление: pull-модель агента на ноде

1. **Агент** (лёгкий сервис на каждой ноде) периодически или по long-poll запрашивает у API **задания** (или забирает снимок желаемого состояния: hash конфига, версия).
2. Бэкенд хранит для ноды очередь/версию; агент применяет изменения локально (`xray` reload, проверка порта) и отчитывается **результатом** и метриками.
3. **Аутентификация**: mTLS или node token + ротация; без интерактивного SSH для рутинных операций.

## Минимальный MVP

- HTTP(S) из ноды к API только **исходящий** (удобно за NAT).
- Эндпоинты вида: «получить задание», «подтвердить выполнение», «heartbeat + версия конфига».
- Бэкенд помечает ноду недоступной по heartbeat; не шлёт критичные операции через SSH, пока агент не подтвердил доставку.

## Черновой контракт API (для реализации)

Все запросы — **исходящие с ноды**. Базовый префикс, например `/api/internal/node/v1` (защита: mTLS или `Authorization: Bearer <node_token>`).

| Метод | Назначение |
|--------|------------|
| `POST /heartbeat` | Тело: `node_id`, `config_hash`, `xray_running`, `agent_version`, опционально метрики (CPU, открытые порты). Ответ: `200` + `{ "next_poll_sec": 30 }` или команда ниже. |
| `GET /assignment?since=<cursor>` | Long-poll или короткий poll: задание на применение конфига / reload / проверку. Пустой ответ = нет работы. |
| `POST /assignment/{id}/result` | Итог: `status` (ok/failed), `message`, `applied_config_hash`, `xray_reloaded_at` (ISO8601). |

**Задание (пример JSON):**

```json
{
  "id": "uuid",
  "type": "apply_xray_config",
  "config_b64": "...",
  "expected_hash": "sha256:...",
  "deadline_at": "2026-03-25T12:00:00Z"
}
```

**Состояние на бэкенде (логически):** для каждой ноды — `desired_config_hash`, `last_reported_hash`, `last_heartbeat_at`, `last_assignment_id`, очередь необработанных заданий. SSH-путь остаётся для ручного вмешательства и миграции.

## Аутентификация и секреты

- **Вариант A:** клиентский сертификат ноды, CA на API; ротация через выдачу нового cert в защищённом канале.
- **Вариант B:** одноразовый или ротируемый **node token** в конфиге агента; API проверяет токен → `node_id`; ротация через админку / новый bootstrap.

Запрещено класть долгоживущий root SSH в агент — только то, что нужно для локального `systemctl`/файлов конфига под непривилегированным пользователем с `sudo` на whitelist-команды (если вообще нужен).

## Миграция (фазы)

- **Фаза 1:** агент дублирует только **readiness** (сообщает версию/хеш); запись по-прежнему SSH. Дашборд: расхождение `desired_hash` vs `last_reported_hash`.
- **Фаза 2:** запись конфига и reload переводятся на команды через агент; SSH — аварийный путь и миграция старых нод.
- **Фаза 3:** отключение SSH для рутины; остаётся break-glass доступ.

Код бэкенда: рядом с существующими менеджерами Xray/SSH в `backend/infrastructure/external/` (и отдельный модуль очереди заданий при необходимости).

## Наблюдаемость

- Структурированные логи: `[edge_agent_heartbeat]`, `[edge_agent_assignment]` с `node_id`, `latency_ms`, `result`.
- Алерты: нет heartbeat N минут; доля `assignment` с `failed`; отставание `last_reported_hash` от `desired` дольше порога.
- Практический runbook и SQL: [EDGE_AGENT_RUNBOOK.md](./EDGE_AGENT_RUNBOOK.md), [edge_agent_ops_queries.sql](./edge_agent_ops_queries.sql).

Этот файл — архитектурный эскиз и контракт для задачи на внедрение; схема БД и точные URL согласуются с существующим API-стилем проекта.

## Фаза 1 в репозитории

- **API:** `POST /api/internal/node/v1/heartbeat` — модуль `backend/api/internal_node.py` (роутер подключён в `backend/main.py`). Лог строк: `[edge_agent_heartbeat]`.
- **Миграция колонок:** `backend/migrations/add_edge_agent_server_columns.sql`; поля на модели `Server`: `edge_agent_token_hash`, `edge_last_heartbeat_at`, `edge_reported_config_hash`, `edge_agent_version`.
- **Скрипт и systemd на ноде:** каталог `scripts/edge-node/` (`heartbeat.sh`, примеры `.service` / `.timer`, README).

## Фаза 2 в репозитории

- **Очередь:** таблица `edge_node_assignments` (миграция `backend/migrations/add_edge_node_assignments_table.sql`), модель `EdgeNodeAssignment`.
- **Agent API:** `GET /api/internal/node/v1/assignment?node_id=…`, `POST /api/internal/node/v1/assignment/{id}/result?node_id=…` — те же логи с префиксом `[edge_agent_assignment]` (`action=poll` / `action=result`).
- **Admin API:** `POST /api/admin/servers/{server_id}/edge-assignments` — постановка задания (`config_b64`, `expected_hash`, …). Нужен настроенный `edge_agent_token_hash` у сервера.
- **Нода:** `scripts/edge-node/poll-and-apply.sh` + примеры `grani-edge-poll.service.example` / `grani-edge-poll.timer.example`; см. `scripts/edge-node/README.md`.
- **Celery** `vpn.apply_xray_config` и **`RemoteVPNManager.update_xray_config`**: при `edge_agent_token_hash` конфиг уходит в очередь (`services/edge_enqueue.py`, `try_commit_apply_xray_config_edge`); для пути SSH-only в `add_xray_client` / `remove_xray_client` после edge не вызывается `reload_xray` по SSH (перезагрузку делает агент).

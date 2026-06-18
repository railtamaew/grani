# Edge-agent: heartbeat (phase 1)

Matches `POST /api/internal/node/v1/heartbeat` and `docs/EDGE_AGENT_SKETCH.md` in this repo.

**Выкат и саппорт:** [docs/EDGE_AGENT_RUNBOOK.md](../../docs/EDGE_AGENT_RUNBOOK.md) (чеклисты, curl, SQL, типовые сбои).

## Database migration (API server)

Apply:

1. `backend/migrations/add_edge_agent_server_columns.sql` (фаза 1)
2. `backend/migrations/add_edge_node_assignments_table.sql` (фаза 2 — очередь заданий)

## Node token

Store **SHA-256 (hex)** of the secret in `servers.edge_agent_token_hash`, not the plain token.

```bash
python3 -c "import hashlib; print(hashlib.sha256(b'YOUR_SECRET').hexdigest())"
```

```sql
UPDATE servers SET edge_agent_token_hash = '<hex>' WHERE id = <node_id>;
```

Put the plain secret on the node (e.g. `/etc/grani-edge/token`, mode `0600`).

## Install on node

1. Copy `heartbeat.sh` to `/usr/local/bin/grani-edge-heartbeat` and `chmod +x`.
2. Create `/etc/default/grani-edge` (see variables below).
3. Install unit + timer from the `.example` files in this directory, then `systemctl enable --now grani-edge-heartbeat.timer`.
   Рекомендуемые интервалы для снижения шума:
   - heartbeat timer: `OnUnitActiveSec=30s` (скрипт сам отправит не чаще `MIN_INTERVAL_OK_SEC`, по умолчанию 120s)
   - poll timer: `OnUnitActiveSec=30s` (скрипт сам опросит assignment не чаще `POLL_MIN_EMPTY_SEC`, по умолчанию 180s при пустой очереди)

### Example `/etc/default/grani-edge`

```bash
GRANI_API_BASE=https://api.example.com
GRANI_NODE_ID=1
GRANI_NODE_TOKEN_FILE=/etc/grani-edge/token
GRANI_XRAY_CONFIG=/usr/local/etc/xray/config.json
GRANI_AGENT_VERSION=1
GRANI_EDGE_STATE_DIR=/var/lib/grani-edge
GRANI_HEARTBEAT_MIN_INTERVAL_OK_SEC=120
GRANI_HEARTBEAT_MIN_INTERVAL_FAIL_SEC=30
GRANI_ASSIGNMENT_POLL_MIN_EMPTY_SEC=180
GRANI_ASSIGNMENT_POLL_MIN_WORK_SEC=30
```

Requires on node: `curl`, `jq`, `sha256sum`.

## Phase 2: assignments (poll + apply Xray config)

- **Agent → API:** `GET /api/internal/node/v1/assignment?node_id=<id>` (Bearer token), затем `POST /api/internal/node/v1/assignment/<uuid>/result?node_id=<id>` с телом `{ "status": "ok"|"failed", "message", "applied_config_hash", "xray_reloaded_at" }`.
- **Admin → API:** `POST /api/admin/servers/{server_id}/edge-assignments` (admin JWT) с телом `assignment_type`, `config_b64`, `expected_hash`, опционально `deadline_at`. Сервер должен уже иметь `edge_agent_token_hash`.

Скрипт **`poll-and-apply.sh`**: опрашивает assignment; для `apply_xray_config` декодирует base64, сверяет `sha256:` с `expected_hash`, пишет в `GRANI_XRAY_CONFIG`, делает `systemctl reload` (или `restart`) юнита `GRANI_XRAY_SYSTEMD_UNIT` (по умолчанию `xray`). Запускать от **root** на ноде (или доработать права/sudo).

Пример второго таймера (реже heartbeat), например раз в 90 с: скопировать `grani-edge-heartbeat.service` в `grani-edge-poll.service` с `ExecStart=/usr/local/bin/grani-edge-poll` (symlink на `poll-and-apply.sh`), отдельный `grani-edge-poll.timer` с `OnUnitActiveSec=90`.

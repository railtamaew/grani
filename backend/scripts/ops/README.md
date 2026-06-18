# Edge alerts (SQL + Telegram)

Скрипт: `backend/scripts/ops/edge_alerts_check.py`

Проверяет:
- пропавший/просроченный heartbeat (`servers.edge_last_heartbeat_at`);
- долгие `pending` / `dispatched` в `edge_node_assignments`;
- новые `failed` assignment за окно времени.

Возврат кода:
- `0` — проблем нет;
- `1` — есть активные алерты;
- `2` — runtime ошибка.

## Переменные окружения

- `DATABASE_URL` (обязательно)
- `TELEGRAM_BOT_TOKEN` (опционально)
- `TELEGRAM_CHAT_ID` (опционально)
- `EDGE_ALERT_HOST_TAG` (опционально, метка в тексте уведомления)

Пороговые значения (опционально):
- `EDGE_ALERT_HEARTBEAT_STALE_SEC` (default `180`)
- `EDGE_ALERT_PENDING_STALE_SEC` (default `300`)
- `EDGE_ALERT_DISPATCHED_STALE_SEC` (default `900`)
- `EDGE_ALERT_FAILED_WINDOW_SEC` (default `900`)
- `EDGE_ALERT_STATE_FILE` (default `/tmp/edge-alerts-state.json`)

## Ручной запуск

```bash
cd /opt/grani/backend
python3 scripts/ops/edge_alerts_check.py --dry-run --verbose
```

## Cron (каждую минуту)

Пример crontab:

```cron
* * * * * cd /opt/grani/backend && /usr/bin/python3 scripts/ops/edge_alerts_check.py >> /var/log/grani/edge-alerts.log 2>&1
```

## systemd (альтернатива cron)

Пример `service` (`/etc/systemd/system/grani-edge-alerts.service`):

```ini
[Unit]
Description=GRANI edge alerts check (SQL + Telegram)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/grani-edge-alerts
WorkingDirectory=/opt/grani/backend
ExecStart=/usr/bin/python3 /opt/grani/backend/scripts/ops/edge_alerts_check.py
```

Пример `timer` (`/etc/systemd/system/grani-edge-alerts.timer`):

```ini
[Unit]
Description=Run GRANI edge alerts check every minute

[Timer]
Unit=grani-edge-alerts.service
OnBootSec=45
OnUnitActiveSec=60
AccuracySec=10
Persistent=true

[Install]
WantedBy=timers.target
```

Активация:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now grani-edge-alerts.timer
sudo systemctl status grani-edge-alerts.timer --no-pager
```

## Анти-флуд и recovery

Скрипт хранит state (`EDGE_ALERT_STATE_FILE`) с fingerprint текущих проблем:
- если состав проблем не менялся, повторно не спамит;
- когда состояние нормализуется, отправляет recovery сообщение один раз.

# Backend deployment

Операционный runbook (запуск, проверка, мониторинг): **[OPERATIONS.md](OPERATIONS.md)**.

## Production checklist (~1000 users)

For production with multiple workers, set:

| Variable | Value | Note |
|----------|--------|------|
| `ENV` | `production` | Required |
| `USE_GUNICORN` | `1` | Use Gunicorn + Uvicorn workers |
| `GUNICORN_WORKERS` | `4` | Tune to CPU or 2–4 for I/O |
| `CACHE_BACKEND` | `redis` | Required when workers > 1 |
| `RATE_LIMIT_STORE` | `redis` | Required when workers > 1 |
| `REDIS_URL` | `redis://host:6379/0` | If Redis not on localhost |
| `DATABASE_URL` | … | Use strong password, not default |
| `SECRET_KEY` | … | Min 32 chars, set via env |

Example:

```bash
export ENV=production
export USE_GUNICORN=1
export GUNICORN_WORKERS=4
export CACHE_BACKEND=redis
export RATE_LIMIT_STORE=redis
export REDIS_URL=redis://redis:6379/0
./start_backend.sh
```

## Single process (development)

```bash
uvicorn main:app --host 0.0.0.0 --port 8000
```

## Multi-worker (production, recommended for ~1000 users)

Use Gunicorn with Uvicorn workers so the event loop is not blocked by sync code and multiple workers can handle concurrent requests:

```bash
gunicorn main:app -w 4 -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8000
```

- `-w 4`: number of worker processes (tune to CPU count or 2–4 for I/O bound).
- `-k uvicorn.workers.UvicornWorker`: use Uvicorn's async worker inside each Gunicorn process.

Set `CACHE_BACKEND=redis` and `RATE_LIMIT_STORE=redis` when using multiple workers so cache and rate limits are shared.

## Timeouts

- SSH operations use a 30s timeout (see `services/ssh_manager.py`).
- For request-level timeouts (e.g. 60–90s), configure Gunicorn or the reverse proxy (e.g. `proxy_read_timeout` in nginx).

## start_backend.sh

By default runs a single uvicorn process. To use Gunicorn, set:

```bash
export USE_GUNICORN=1
export GUNICORN_WORKERS=4
./start_backend.sh
```

## Celery worker (VPN Xray apply)

The API uses Celery to apply Xray config to VPN servers asynchronously after `create-client`. If the worker is not running, config is applied synchronously over SSH and create-client can be slow or time out.

- **Run worker** (from backend root, with same `PYTHONPATH` / venv as API):
  ```bash
  celery -A services.celery_app worker -l info
  ```
  Ensure the worker process imports VPN tasks, e.g. by importing `services.tasks.vpn_tasks` in `celery_app` or by using an app that loads them.

- **Verify task is registered:**
  ```bash
  celery -A services.celery_app inspect registered
  ```
  You should see `vpn.apply_xray_config` in the list. If not, ensure `services.tasks.vpn_tasks` is loaded (e.g. in `celery_app` via `include= [...]` or by importing it from the worker entrypoint).

- **Broker:** Same `REDIS_URL` as API (used as Celery broker and result backend). If Redis is down, the API falls back to applying Xray config synchronously.

- **Очереди:** Задачи маршрутизируются по очередям: `vpn` (apply Xray config), `default` (логи клиентов, подписки, уведомления). Один воркер обрабатывает все очереди:
  ```bash
  celery -A services.celery_app worker -l info
  ```
  При высокой нагрузке можно запустить отдельный воркер только для VPN (меньше задержка apply):
  ```bash
  celery -A services.celery_app worker -l info -Q vpn
  ```
  и основной воркер для остальных задач:
  ```bash
  celery -A services.celery_app worker -l info -Q default,monitoring
  ```

## Перед релизом мобильного приложения: `ping_ms` и health-check

1. **Код на сервере** — задеплойте актуальный backend (образ с `iputils-ping` и маршрутизацией задач мониторинга).
2. **Celery worker** должен слушать очереди **`default`, `vpn`, `monitoring`** (в `server-config/docker/docker-compose.yml` это уже задано через `-Q default,vpn,monitoring`). Иначе задача `server.check_server_health` не выполнится.
3. **Celery Beat** — контейнер `celery_beat` с `celery -A celery_beat beat` должен быть запущен; расписание в `backend/celery_beat.py` (в т.ч. `check-server-health` каждые 60 с).
4. **Сеть** — с хоста/контейнера API и воркера должны быть доступны ICMP или TCP до IP нод (иначе в БД останется `ping_ms=null`, сработает только клиентский TCP-замер в приложении).
5. **Деплой через Docker** (на хосте с репозиторием и `server-config/.env`):
   ```bash
   bash server-config/docker/deploy.sh
   ```
   Либо вручную: `docker compose build api celery celery_beat && docker compose up -d api celery celery_beat nginx`.

## Post-deploy verification

After deploying API and (optionally) Celery, run from backend root:

```bash
python3 scripts/verify_vpn_deploy.py
```

The script checks: `REDIS_URL`, `CACHE_BACKEND` / `RATE_LIMIT_STORE` when using multiple workers, and Celery worker availability. Fix any warnings before production.

Manual checks: API logs should show "Xray config cache warmed for server_id=..." after startup; repeated create-client for the same device should log "Create-client fast path: клиент уже в кэше".

## Running tests with Redis

To run tests that require Redis (cache and rate-limit backends):

```bash
# Ensure Redis is running (e.g. docker run -d -p 6379:6379 redis:alpine)
pytest -m redis -v
```

All other tests run with in-memory backends and do not require Redis.

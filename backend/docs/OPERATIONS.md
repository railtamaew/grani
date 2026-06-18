# Эксплуатация бэкенда (runbook)

Краткий чеклист запуска и проверки в production. Подробности — в [DEPLOYMENT.md](DEPLOYMENT.md) и в [docs/PERFORMANCE_OBSERVABILITY.md](../../docs/PERFORMANCE_OBSERVABILITY.md) в корне репозитория.

---

## 1. Переменные окружения

Перед запуском задать (env или `/etc/grani/secrets.env`):

| Переменная | Обязательно в prod | Пример |
|------------|--------------------|--------|
| `ENV` | да | `production` |
| `DATABASE_URL` | да | `postgresql://user:pass@host:5432/dbname` |
| `SECRET_KEY` | да | не менее 32 символов |
| `API_URL` | да | `https://api.example.com` (не localhost) |
| `REDIS_URL` | да при Celery/Redis-кэше | `redis://redis:6379/0` |
| `CACHE_BACKEND` | да при workers > 1 | `redis` |
| `RATE_LIMIT_STORE` | да при workers > 1 | `redis` |
| `USE_GUNICORN` | рекомендуется | `1` |
| `GUNICORN_WORKERS` | при Gunicorn | `4` |
| `API_BASE_URL_FALLBACKS` | опционально | запасные базы API в bootstrap, через запятую без пробелов |

Остальное по необходимости: SMTP/SES, OAuth, домены, Boring HTTPS и т.д. (см. `.env.example`).

---

## 2. Зависимости

- **PostgreSQL** — доступна по `DATABASE_URL`
- **Redis** — доступна по `REDIS_URL` (для Celery и при `CACHE_BACKEND=redis`)

---

## 3. Запуск API

Из корня backend (тот же venv/PYTHONPATH, что и для приложения):

**Один процесс (dev/тест):**
```bash
uvicorn main:app --host 0.0.0.0 --port 8000
```

**Production (рекомендуется):**
```bash
export USE_GUNICORN=1
export GUNICORN_WORKERS=4
./start_backend.sh
```
или напрямую:
```bash
gunicorn main:app -w 4 -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8000
```

---

## 4. Запуск Celery

Из корня backend, тот же venv и `REDIS_URL`:

**Один воркер на все очереди:**
```bash
celery -A services.celery_app worker -l info
```

**Разделение при высокой нагрузке:**
```bash
# Воркер только для VPN (apply Xray config)
celery -A services.celery_app worker -l info -Q vpn

# Воркер для логов и остального
celery -A services.celery_app worker -l info -Q default,monitoring
```

Проверка зарегистрированных задач:
```bash
celery -A services.celery_app inspect registered
```
Ожидаются: `vpn.apply_xray_config`, `vpn.save_client_logs` и др.

---

## 5. Проверка после деплоя

Из корня backend:
```bash
python3 scripts/verify_vpn_deploy.py
```
Устранить все предупреждения перед production.

### Bootstrap `GET /api/vpn/bootstrap` (granilink, порт 8444)

Код в `api/bootstrap.py` добавляет в `api_base_urls` основной `API_URL`, записи из **`API_BASE_URL_FALLBACKS`** (через запятую, без пробелов), затем зеркала через HU-BUD-01: `https://api.granilink.com/api`, `https://api.granilink.com:8444/api`, `https://45.12.132.94:8444/api` (8444 — запасной HTTPS nginx; 8443 на ноде — VMESS).

Проверка снаружи после выката:

```bash
curl -sS https://api.granilink.com/api/vpn/bootstrap
```

Ожидается несколько URL в массиве `api_base_urls`, включая granilink и при необходимости `:8444`.

**Выкат на сервер API (Docker, типичный сценарий):** на машине, где крутится `granivpn_api`, с репозиторием и `docker-compose`:

```bash
cd /path/to/grani   # каталог с клоном и server-config/docker или ваш compose
git pull
docker compose -f server-config/docker/docker-compose.yml build api
docker compose -f server-config/docker/docker-compose.yml up -d api
```

Имена файла/сервиса подставьте свои. Затем снова `curl` bootstrap.

**Без обновления кода** (только если на сервере уже есть логика разбора `API_BASE_URL_FALLBACKS` в bootstrap): в env контейнера API задать, например:

`API_BASE_URL_FALLBACKS=https://api.granilink.com/api,https://api.granilink.com:8444/api,https://45.12.132.94:8444/api`

и перезапустить контейнер. Если прод всё ещё отдаёт один URL — нужен полный выкат образа с актуальным `bootstrap.py`.

**По логам API:**
- После старта: сообщения вида `Xray config cache warmed for server_id=...`
- При повторном create-client для того же устройства: `Create-client fast path: клиент уже в кэше`

---

## 6. Мониторинг

- **Проверка доступности API (для cron или алертов):** из корня backend или с сервера:
  ```bash
  API_HEALTH_URL=http://127.0.0.1:8010/health bash scripts/check_production_health.sh
  ```
  При успехе: `OK health 200 ...`, exit 0. При недоступности или не 200: exit 1. Пример cron (каждые 5 мин):
  ```bash
  */5 * * * * cd /opt/grani/backend && API_HEALTH_URL=http://127.0.0.1:8010/health bash scripts/check_production_health.sh || echo "API health check failed"
  ```
- **Метрики (админский JWT):** `GET /api/admin/metrics` — задержки и счётчики по маршрутам, 5xx.
- **Ключевые эндпоинты и целевые значения:** см. [docs/PERFORMANCE_OBSERVABILITY.md](../../docs/PERFORMANCE_OBSERVABILITY.md) в корне репозитория (bootstrap, send-code, verify-code, create-client, /health).
- При таймаутах или 5xx: логи API и Nginx, нагрузка на БД и Redis.

---

## 7. VPN-ноды (Xray)

- Настройка новой ноды: `python3 scripts/setup_xray_server.py` (задать `SSH_PASSWORD`, при необходимости поправить хост в скрипте). Скрипт выставляет LimitNOFILE для Xray.
- Доп. настройки нод: [docs/VPN_NODE_TUNING.md](../../docs/VPN_NODE_TUNING.md) в корне репозитория.

---

## 8. Полезные ссылки

- [DEPLOYMENT.md](DEPLOYMENT.md) — деплой, Celery, таймауты, тесты
- В корне репозитория: `docs/PERFORMANCE_OBSERVABILITY.md`, `docs/SERVER_OVERLOAD_ANALYSIS.md`, `docs/VPN_NODE_TUNING.md` — метрики, разбор перегрузок, настройка VPN-нод

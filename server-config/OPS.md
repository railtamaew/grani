# GRANI backend / Docker — операционный конспект

## После деплоя

1. `docker compose -f server-config/docker/docker-compose.yml up -d` (или ваш override).
2. Nginx: `docker exec granivpn_nginx nginx -t && docker exec granivpn_nginx nginx -s reload`.
3. Redis: проверить `INFO memory`, `maxmemory` и `maxmemory-policy` (в compose заданы `512mb` + `allkeys-lru`, переопределение: `REDIS_MAXMEMORY` в окружении хоста при `docker compose up`).

## Базовый снимок (до/после изменений)

```bash
bash /opt/grani/server-config/scripts/collect_baseline.sh
```

## Ротация логов API (хост)

Шаблон: `server-config/logrotate/granivpn-docker-api.conf` — скопировать в `/etc/logrotate.d/` на сервере, путь к логам: `/opt/grani/logs/docker-api/*.log` (том из compose).

## Лимиты Nginx

- Зона `api`: **30 req/s** на IP, **burst 50** на пути кроме точного `GET /health` на `api.granilink.com` (health без `limit_req`).

## Масштабирование API

- Сейчас: один сервис `api`, `GUNICORN_WORKERS=4`. Общее число соединений к Postgres: `(database_pool_size + database_max_overflow) * workers` — не превышать `max_connections` в PostgreSQL.
- Горизонтальное масштабирование: несколько реплик API за балансировщиком + общий Redis для кэша и rate limit.

## Prometheus (`/metrics/prometheus`)

1. В env API: `METRICS_PROMETHEUS_ENABLED=true` (и `METRICS_ENABLED` не отключать).
2. Nginx на `api.granilink.com`: разрешён только **localhost** к `location = /metrics/prometheus`. Scrape с хоста: `curl -sS http://127.0.0.1:8010/metrics/prometheus` (порт проброшен compose) или SSH-туннель. Для IP Prometheus в VPC добавьте в `nginx.conf` в этот `location` строку `allow a.b.c.d;` и `nginx -s reload`.
3. С интернета путь закрыт (`deny all` после `allow`).

## PostgreSQL `pg_stat_statements`

В `docker-compose` для `postgres` задан `shared_preload_libraries=pg_stat_statements`. На **уже существующем** томе после обновления compose перезапустите Postgres, затем один раз:

```bash
docker exec granivpn_postgres psql -U granivpn_user -d granivpn -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
```

Просмотр топа запросов: `SELECT * FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 20;` (под суперпользователем или ролью с правами на представление).

## Мобильный интернет / DPI

- Симптомы «таймаут с мобильного»: смотреть Nginx `rt=`/`urt=`, Cloudflare (если есть), не только логи приложения.
- Клиент: перебор баз в `ApiClient`, bootstrap в `AuthService.fetchBootstrapUrls`, логи — `ConnectionLogger` с ограничением очереди.

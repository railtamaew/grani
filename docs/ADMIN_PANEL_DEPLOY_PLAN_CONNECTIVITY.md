# План деплоя админки (Observability connectivity)

Цель: выкатить изменения админ-панели с блоком мониторинга подключения (`p50/p95`, `degraded rate`, `stage errors`, `network split`) и безопасно проверить прод.

## 1) Pre-deploy (локально)

```bash
cd /opt/grani/admin-panel
npm ci
npm run build
```

Проверить, что backend отдает новый endpoint:

```bash
curl -sS "https://<API_HOST>/api/admin/observability/metrics/connectivity-summary?hours=24"
```

Ожидается JSON c полями:
- `duration_by_protocol`
- `stage_errors`
- `degraded_rate`
- `network_split`
- `signals.dataplane_not_ready_after_apply`

## 2) Deploy (frontend)

Если используется серверный хостинг админки:

```bash
cd /opt/grani
./scripts/deploy-admin-build.sh <user@server>
```

Если деплой вручную:

```bash
rsync -avz --delete /opt/grani/admin-panel/build/ <user@server>:/opt/grani/admin-panel/build/
```

После копирования на сервере:

```bash
sudo bash /opt/grani/server-config/fix-admin-403.sh
```

## 3) Deploy (backend API)

Нужен деплой backend с endpoint:
`GET /api/admin/observability/metrics/connectivity-summary`

Минимум: обновить код backend и перезапустить API-процесс/контейнер.

## 4) Smoke-check после выката

Проверка UI:
- открыть `https://admin.granilink.com`
- зайти в `Observability`
- убедиться, что отображаются:
  - `Мониторинг подключения (последние 24ч)`
  - `Latency p50/p95`
  - `Degraded rate`
  - таблица `Ошибки по стадиям`
  - таблица `Сеть: Wi-Fi / Mobile / Other`

Проверка API:

```bash
curl -i "https://<API_HOST>/api/admin/observability/metrics/connectivity-summary?hours=24"
```

Ожидается `HTTP 200`.

## 5) Rollback (если что-то пошло не так)

1. Вернуть предыдущий `build/` админки из бэкапа или последнего стабильного артефакта.
2. Откатить backend до предыдущего релиза.
3. Повторно проверить вход в админку и страницу `Observability`.

## 6) Окно релиза и контроль

- Время релиза: вне пиковых часов.
- После релиза 30-60 минут контролировать:
  - ошибки загрузки страницы в браузере,
  - `5xx/4xx` на endpoint summary,
  - корректность чисел в блоке мониторинга.

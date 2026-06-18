# Деплой админки: появление маршрута `/observability` на admin.granilink.com

## Диагностика (почему редирект на `/dashboard`)

1. В `admin-panel/src/App.tsx` объявлен catch-all маршрут:
   - `path="*"` → `<Navigate to="/dashboard" replace />`
2. Если в **собранном** `build/static/js/*.js` **нет** страницы Observability и маршрута `/observability`, React Router считает URL неизвестным и срабатывает `*`.
3. Nginx для `admin.granilink.com` в репозитории уже настроен под SPA (`try_files $uri $uri/ /index.html;` в `server-config/nginx/granivpn-servers.conf`). Значит проблема почти всегда в **устаревшем каталоге `build` на сервере**, а не в nginx.

**Итог:** нужно заново собрать админ-панель из актуального кода и **залить `build/`** на хост, где лежит `/opt/grani/admin-panel/build`.

## Шаги на машине разработки / CI

```bash
cd /opt/grani/admin-panel
npm ci
npm run build
```

Проверка, что маршрут попал в бандл (после `npm run build`):

```bash
grep -R '/observability' build/static/js/ -q && echo OK || echo "FAIL: нет /observability в бандле"
```

## Шаги на production-сервере

Путь по умолчанию из конфига nginx в репозитории: `root /opt/grani/admin-panel/build;`

### Вариант A: `rsync` (рекомендуется)

С машины, где есть свежий `build/`:

```bash
rsync -avz --delete /opt/grani/admin-panel/build/ user@YOUR_SERVER:/opt/grani/admin-panel/build/
```

Скрипт-обёртка в репозитории:

```bash
./scripts/deploy-admin-build.sh user@YOUR_SERVER
```

(перед этим локально выполнить `npm run build` в `admin-panel/`.)

### Вариант B: сборка прямо на сервере

```bash
ssh user@YOUR_SERVER
cd /opt/grani/admin-panel
git pull
npm ci
npm run build
```

### Права и 403

Если после заливки отдаётся 403:

```bash
sudo bash /opt/grani/server-config/fix-admin-403.sh
```

См. также `server-config/nginx/ADMIN-403.md`.

### Nginx

После замены только статики **перезагрузка nginx обычно не нужна**. Если меняли конфиг:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

## Проверка после деплоя

1. Жёсткое обновление страницы в браузере (или инкогнито), чтобы сбросить кэш старого `main.*.js`.
2. Открыть `https://admin.granilink.com/observability` под пользователем с ролью `support`, `admin` или `owner`.
3. Убедиться, что в боковом меню есть пункт **Observability**.

## Backend для страницы Observability

Страница дергает API под префиксом `/api/admin/observability/...`. Если UI открылся, но данные пустые/ошибки:

- убедитесь, что на API выкачен backend с роутером observability;
- применена миграция БД (таблицы `observability_*`), см. `backend/scripts/apply_observability_v2_migration.py` и документ `MIGRATION_AND_BACKFILL_PLAN.md`.

## CI

В workflow `.github/workflows/admin-panel.yml` добавлена проверка: после `npm run build` ищется строка `/observability` в артефакте сборки, чтобы не выкатывать регресс без маршрута.

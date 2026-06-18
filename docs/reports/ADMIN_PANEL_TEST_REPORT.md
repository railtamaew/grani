# Отчет тестирования админ‑панели (Cursor)

Дата: 2026-01-27

## Среда
- Backend: `ENV=development python3 -m uvicorn main:app --port 8010`
- Frontend: `npm start` (React dev server) с `REACT_APP_API_URL=http://localhost:8010`
- Runtime config: `admin-panel/public/runtime-config.js` → `apiBaseUrl="http://localhost:8010"`
- Примечание: `npm start` требовал `DANGEROUSLY_DISABLE_HOST_CHECK=true` для обхода ошибки dev‑server
- Production admin: `https://admin.granilink.com` (Nginx раздаёт `/opt/grani/admin-panel/build`, `/api/` проксируется на `http://127.0.0.1:8010`)

## Выполненные проверки
### Backend (unit tests)
- `pytest tests/test_auth_service.py` — **33 passed**

### Backend (smoke)
- `GET /health` на `http://localhost:8010`  
  Ответ: `status=unhealthy` из‑за ошибки SQLAlchemy (требуется `text('SELECT 1')`), при этом проверки устройств/серверов возвращаются.
- Production API (smoke, `https://admin.granilink.com`):
  - `GET /api/admin/me` — 200
  - `GET /api/admin/users?page=1&limit=5` — 200
  - `GET /api/admin/devices?page=1&limit=5` — 200
  - `GET /api/admin/trials?page=1&limit=5` — 200
  - `GET /api/admin/subscriptions?page=1&limit=5` — 200
  - `GET /api/admin/payments?page=1&limit=5` — 200
  - `GET /api/admin/servers` — 200
  - `GET /api/admin/protocols` — 200
  - `GET /api/admin/logs/clients?page=1&limit=5` — 200
  - `GET /api/admin/audit-log?limit=5` — 200
  - `GET /api/admin/stats/auth-providers` — 200
  - `GET /api/admin/load/alerts?threshold=80` — 200
  - Date filters:
    - `GET /api/admin/payments?created_from=2025-01-01` — 200
    - `GET /api/admin/subscriptions?start_date_from=2025-01-01` — 200

### UI (Cursor Browser)
- Вход выполнен под Owner (email: `rail.tamaew@gmail.com`).
- Скриншоты:
  - `admin-login-filled-2.png` (форма логина, заполнена)
  - `admin-dashboard.png`
  - `admin-users.png`
  - `admin-subscriptions.png`
  - `admin-payments.png`
  - `admin-servers.png`
  - `admin-protocols.png`
  - `admin-incidents.png`
  - `admin-client-logs.png`
  - `admin-audit-log.png`
  - `admin-settings-feature-flags.png`
  - `admin-settings-min-versions.png`
  - `admin-settings-admins.png`
  - `admin-auth-codes.png`
- Навигация по разделам выполняется, страницы открываются, видны пустые состояния при отсутствии данных.
- Ошибки UI/console (наблюдались в процессе прогона):
  - CORS блокировки при запросах к `http://localhost:8010`:
    - `/api/admin/audit-log`
    - `/api/admin/settings`
    - `/api/admin/settings/admins`
    - `/api/admin/auth/me`
  - Страница `Настройки` показывает баннер “Ошибка загрузки администраторов”.
  - Страница `Коды авторизации` логирует “Error loading auth codes”.
  - Предупреждения React Router future flags (v7_startTransition, v7_relativeSplatPath).

### UI (Production: https://admin.granilink.com)
- Логин под Owner успешен, переход на `dashboard`.
- Скриншоты:
  - `admin-granivpn-login-filled.png`
  - `admin-granivpn-dashboard.png`
  - `admin-granivpn-users.png`
  - `admin-granivpn-subscriptions.png`
  - `admin-granivpn-payments.png`
  - `admin-granivpn-servers.png`
  - `admin-granivpn-protocols.png`
  - `admin-granivpn-incidents.png`
  - `admin-granivpn-client-logs.png`
  - `admin-granivpn-audit-log.png`
  - `admin-granivpn-settings-feature-flags.png`
  - `admin-granivpn-settings-min-versions.png`
  - `admin-granivpn-settings-admins.png`
  - `admin-granivpn-auth-codes.png` (до фикса, crash)
  - `admin-granivpn-auth-codes-ok.png` (после фикса)
  - `admin-devices-page.png`
  - `admin-trials-page.png`
- Наблюдаемые проблемы:
  - `Настройки`: баннер “Ошибка загрузки настроек” — исправлено после миграции `system_settings` и фикса RBAC.
  - `Коды авторизации`: падение UI (ErrorBoundary) с ошибкой `Cannot read properties of undefined (reading 'length')` — исправлено в новой сборке.
  - Доп. скриншоты после исправлений:
    - `admin-granivpn-settings-feature-flags-ok.png`
    - `admin-granivpn-settings-min-versions-ok.png`
    - `admin-granivpn-settings-admins-ok.png`
  - Новые страницы:
    - `Устройства` и `Триалы` открываются, фильтры и таблицы отображаются корректно.
  - RBAC:
    - Добавлена роль‑проверка на уровне маршрутов и критичных действий (удаление устройства, установка trial).
  - Экспорт CSV:
    - Добавлен на страницах Users/Subscriptions/Payments/Devices/Trials/Servers/Incidents/Client Logs/Audit Log/Protocols.
  - Токен/роль:
    - `/api/admin/me` возвращает реальную роль пользователя для корректного RBAC.
  - Фильтры дат:
    - Payments/Subcriptions поддерживают date‑range фильтры (created/start/end).

## Невыполненные проверки (блокеры)
### UI тесты в встроенном браузере Cursor
- Dev‑среда все еще показывает CORS ошибки при запросах к `http://localhost:8010`; на production это не влияет.
- Встроенный скриншот в Cursor Browser иногда тайм‑аутится, требуется повторная попытка.

## Рекомендации
1. Исправить CORS для `http://localhost:3001` (и/или использовать proxy через `REACT_APP_API_URL=""`), затем повторить прогон UI в dev‑среде.
2. Исправить health‑check БД (обернуть SQL в `text('SELECT 1')`) для чистого статуса.
3. Повторить прогоны страниц `Настройки`, `Audit Log`, `Коды авторизации` после устранения CORS.

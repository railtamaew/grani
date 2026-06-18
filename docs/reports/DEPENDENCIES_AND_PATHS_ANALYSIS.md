# Анализ зависимостей и путей между частями проекта GRANI

Дата: 2025-02-17. Обзор: бэкенд, мобильное приложение, админ-панель, серверная конфигурация (VPN, Nginx), Docker.

---

## 1. Структура проекта

| Компонент | Путь | Стек |
|-----------|------|------|
| Backend API | backend/ | FastAPI, PostgreSQL, Redis, Celery |
| Mobile App | mobile-app/ | Flutter (Dart) |
| Admin Panel | admin-panel/ | React (TypeScript) |
| Server config | server-config/ | Nginx, Docker Compose, .env |
| VPN/серверы | server-config/wireguard, nginx | WireGuard, Xray (на серверах) |
| Emulator/Web | emulator_web/ | Отдельный подпроект |
| Test projects | test-projects/ | vpn-minimal, vpn-native-test |

---

## 2. API: базовые URL и префиксы

**Единая схема:** Backend отдаёт маршруты с префиксом `/api/`. Итоговый URL: `{BASE_URL}/api/{...}`.

| Компонент | Переменная | Ожидаемый формат BASE | Пример |
|-----------|------------|------------------------|--------|
| Mobile App | API_BASE_URL (dart-define) | URL **включая** /api | https://api.granilink.com/api |
| Admin Panel | REACT_APP_API_URL или __GRANI_CONFIG__.apiBaseUrl | URL **без** /api | https://api.granilink.com |
| Backend | API_URL в .env | Базовый URL без /api | https://api.granilink.com |

**Несоответствие — Admin в Docker Compose:** В server-config/docker/docker-compose.yml для сервиса admin задано `REACT_APP_API_URL=https://granilink.com/api`. В админке все пути уже с `/api/` (например `/api/admin/users`). Итог: двойной /api в URL. Рекомендация: задать `REACT_APP_API_URL=https://granilink.com` или `https://api.granilink.com` (без суффикса /api). В server-config/.env уже корректно: `REACT_APP_API_URL=https://api.granilink.com`.

---

## 3. Домены и брендинг

- **granilink.com** — основной прод; **api.granilink.com**, **admin.granilink.com**, **app.granilink.com** — в Nginx и CORS.
- **Несоответствие:** В backend/core/config.py дефолт `domain: str = "grani.ru"`, в allowed_origins есть и admin.grani.ru, app.grani.ru, и admin.granilink.com, app.granilink.com. Везде в server-config, mobile, nginx используется **granilink.com**. Рекомендация: зафиксировать один прод-домен (granilink.com), в backend задавать DOMAIN=granilink.com.

---

## 4. Конфигурация окружений

- **Backend:** .env в backend/, приоритетно /etc/grani/secrets.env. Важно: в Settings поле `allowed_origins`; pydantic-settings маппит env как ALLOWED_ORIGINS. В server-config/.env задаётся **CORS_ORIGINS** — без алиаса в конфиге бэкенда эта переменная не попадёт в allowed_origins. Либо в бэкенде добавить алиас CORS_ORIGINS, либо в server-config использовать ALLOWED_ORIGINS.
- **Docker Compose:** В environment: захардкожены SMTP и AWS ключи у api и celery — секреты не должны храниться в репо; вынести в env_file или Docker secrets.
- **Admin:** Production URL через REACT_APP_API_URL или runtime-config.js (apiBaseUrl).
- **Mobile:** API_BASE_URL через --dart-define, default https://api.granilink.com/api.

---

## 5. Несоответствия по путям и портам

- **Порты:** Backend в Docker 8010:8000, Nginx upstream 127.0.0.1:8010 — согласовано. PostgreSQL 5432, Redis 6379 — единообразно.
- **WireGuard IP:** backend/core/config.py default `wireguard_server_ip = "94.131.107.227"`; server-config/.env `WIREGUARD_SERVER_IP=159.223.199.122`; server-config/env-production.env `WIREGUARD_SERVER_IP=94.131.107.227`. В mobile-app в Xray split-tunnel зашит IP 159.223.199.122. Два разных IP в конфигах; нужно зафиксировать один источник правды и синхронизировать backend, server-config и при необходимости mobile (или получать с API).

---

## 6. Docker

- Сборка: context ../../backend и ../../admin-panel — пути относительно server-config/docker/ корректны.
- Секреты в environment: вынести в env_file/secrets.
- env_file: ../.env и /etc/grani/secrets.env — согласовать приоритет переменных.

---

## 7. Зависимости (схема)

- Mobile App -> API https://api.granilink.com/api; split-tunnel api.granilink.com, IP 159.223.199.122.
- Admin Panel -> API base без /api, пути /api/admin/..., /api/auth/....
- Nginx -> api.granilink.com (или granilink.com) -> 127.0.0.1:8010; admin.granilink.com.
- Backend <- DATABASE_URL, REDIS_URL, API_URL, CORS; /etc/wireguard; -> Celery, Flower.

---

## 8. Рекомендации

1. Исправить REACT_APP_API_URL в docker-compose для admin (убрать /api в конце).
2. CORS: поддержать CORS_ORIGINS в backend или переименовать в server-config в ALLOWED_ORIGINS.
3. Домен: в backend зафиксировать DOMAIN=granilink.com для прод.
4. WireGuard IP: один источник правды (например server-config/.env), синхронизировать backend и mobile.
5. Секреты в docker-compose: убрать из environment, использовать env_file/secrets.
6. Документировать в одном месте таблицу переменных окружения и форматов URL по компонентам.

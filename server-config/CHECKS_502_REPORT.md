# Отчёт проверок (502 Bad Gateway)

**Дата:** 2026-02-15

## Что проверено

### 1. Бэкенд (backend)

- **Импорт приложения:** при запуске обнаружена ошибка в коде — **IndentationError** в `application/services/vpn_operations_service.py`, строка 1008. Из-за неё приложение не могло стартовать, nginx получал отказ от upstream и отдавал 502.
- **Исправление:** удалён дублированный фрагмент (лишние строки `"stats": stats,` и `}` с неверным отступом).
- **После исправления:** `from main import app` выполняется успешно, роуты auth присутствуют: `/api/auth/send-code`, `/api/auth/google/callback`, `/api/auth/verify-code` и др.
- **Тесты:** `tests/test_auth_request_models.py` — 5 passed.

### 2. Nginx

- **Синтаксис:** на машине, где выполнялись проверки, `nginx -t` прошёл успешно (проверяется системный `/etc/nginx/nginx.conf`; конфиги из репозитория нужно подключать на сервере и перезагружать nginx после деплоя).

### 3. Конфигурация (уже сделанные ранее изменения)

- В репозитории для API выставлены таймауты 60s в `server-config/nginx/granivpn-servers.conf` и `granivpn-http-only.conf`.
- Добавлен чеклист диагностики: `server-config/502_DEBUG.md`.

## Рекомендации

1. **Задеплоить исправление** `application/services/vpn_operations_service.py` на сервер и перезапустить бэкенд (uvicorn/gunicorn или systemd-сервис).
2. Убедиться, что бэкенд слушает порт из upstream (в конфиге: `127.0.0.1:8010`).
3. После деплоя проверить: `curl -s -o /dev/null -w "%{http_code}" https://api.granilink.com/api/auth/send-code` (ожидается 422 или 405 при GET без тела, но не 502).
4. При повторной 502 смотреть логи: `sudo tail -50 /var/log/nginx/error.log` и логи приложения.

# Диагностика 502 Bad Gateway (API / Google OAuth)

502 от nginx означает: запрос дошёл до nginx, но **upstream (бэкенд) не вернул нормальный ответ**.

## Чеклист на сервере

1. **Бэкенд запущен**
   - Проверить процесс (uvicorn/gunicorn): `ps aux | grep uvicorn` или `systemctl status granivpn-api` (или как назван сервис).
   - Upstream в конфиге: `server 127.0.0.1:8010` (порт в `granivpn-upstreams.conf`).

2. **Логи nginx**
   - `sudo tail -100 /var/log/nginx/error.log` — смотреть время запроса и сообщение (upstream timed out, connection refused, upstream closed connection).

3. **Логи приложения**
   - Логи FastAPI/uvicorn. Для `/api/auth/google/callback` в коде добавлено сообщение `[google-callback] ========== ЗАПРОС ПОЛУЧЕН ==========` — если его нет, запрос до бэкенда не доходит (nginx отдал 502 до ответа upstream).

4. **Таймауты**
   - В конфигах nginx для API выставлены `proxy_read_timeout 60s`, `proxy_send_timeout 60s`. Если бэкенд отвечает дольше (например, долгий запрос к Google JWKS), nginx отдаст 502. Проверить доступность https://www.googleapis.com/oauth2/v3/certs с сервера.

5. **Конфиг Google OAuth**
   - В env бэкенда задайте одну из переменных: **GOOGLE_OAUTH_CLIENT_IDS**, **GOOGLE_OAUTH_DEFAULT_CLIENT_ID** или **ALLOWED_GOOGLE_CLIENT_IDS** (значение — client id из Google Cloud Console). Если все пусты, эндпоинт вернёт 500 и в логах будет `[google-callback] allowed_google_client_ids не настроен`.

## После изменений

- Nginx: `sudo nginx -t && sudo systemctl reload nginx`
- Бэкенд: перезапуск сервиса (чтобы подхватить изменения кода/конфига).

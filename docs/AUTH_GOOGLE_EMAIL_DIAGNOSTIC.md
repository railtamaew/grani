# Диагностика авторизации: Google OAuth и вход по email

Инструкция для целенаправленной диагностики **авторизации через Google** и **авторизации по email (код на почту)** — по той же структуре, что и правило vpn-diagnostics.

---

## 1. Цепочки запросов

### Google OAuth

```
[Устройство]  GoogleSignIn.signIn() → id_token от Google
       → POST https://api.granilink.com/api/auth/google/callback  { id_token, access_token? }
       → [Nginx] → [API] verify_google_id_token(id_token) → JWKS с https://www.googleapis.com/oauth2/v3/certs
       → создание/обновление User, JWT → ответ { token, refresh_token, user, ... }
```

**Критичные точки:** доступность API с устройства, настройка `allowed_google_client_ids`, доступность Google JWKS с сервера, таймауты nginx/клиента.

### Email (код на почту)

```
[Устройство]  POST /api/auth/send-code  { email }
       → [Nginx] → [API] rate limit (IP/email) → генерация кода → запись в БД (auth_codes)
       → send_verification_email() (Yandex Postbox / AWS SES)
       → ответ { ok: true }

[Устройство]  POST /api/auth/verify-code  { email, code }
       → [Nginx] → [API] rate limit → проверка кода в БД → выдача JWT
       → ответ { token, refresh_token, user, ... }
```

**Критичные точки:** доступность API, rate limit (429), отправка письма (SES/Postbox), совпадение кода (нормализация пробелов).

---

## 2. Серверная сторона (Nginx + API)

| Проверка | Как выполнить | Что искать |
|----------|----------------|-------------|
| Запросы доходят до nginx | `docker exec granivpn_nginx tail -200 /var/log/nginx/access.log` или `grep -E "google/callback|send-code|verify-code" access.log` | Есть ли строки с IP пользователя в момент сбоя. **Если нет** — таймаут/сеть до сервера. |
| Ошибки nginx | `docker exec granivpn_nginx tail -50 /var/log/nginx/error.log` | 502 (upstream timeout), connection refused. Для `/api` в конфиге `proxy_read_timeout 60s`. |
| Логи API (google-callback) | `docker logs granivpn_api --tail 300 2>&1 \| grep -E "google-callback|send-code|verify-code"` | `[google-callback] ========== ЗАПРОС ПОЛУЧЕН ==========` — запрос дошёл до приложения. Дальше: `allowed_google_client_ids не настроен`, ошибки JWKS, 400/409. |
| Логи API (send-code) | То же | `[send-code] ========== НАЧАЛО ОТПРАВКИ КОДА ДЛЯ ...` → успех или `email_send_failed` / ошибка SES. |
| Конфиг Google OAuth | В БД или env: `ALLOWED_GOOGLE_CLIENT_IDS` / `google_oauth_client_ids` / `google_oauth_default_client_id` | Пустой список → 500 «OAuth не настроен». Client ID должен совпадать с приложением (package name / SHA-1 в Google Cloud Console). |
| Доступность JWKS с сервера | На сервере: `curl -sI https://www.googleapis.com/oauth2/v3/certs` | Если API не может скачать ключи — callback вернёт 400 «Не удалось получить ключи Google OAuth». |
| Rate limit (email) | В логах: `[send-code] Rate limit exceeded` или `[verify-code]` | 429 в ответе. Лимиты: send-code 5/мин по IP, 3/мин по email; verify-code 10/мин по IP, 5/мин по email. |

---

## 3. Клиентская сторона

**Почему в logcat видны знаки вопроса вместо русского текста:** сообщения в коде на кириллице, а вывод `debugPrint` в Android logcat часто показывается в кодировке, где кириллица не отображается (например, Latin-1), и символы заменяются на `?`. На логику приложения это не влияет. Чтобы читать логи без искажений, смотрите их в Android Studio с UTF-8 или используйте `adb logcat` с опцией кодировки.

**Логи для анализа времени авторизации:** в коде добавлены строки с префиксом `[auth-timing]` (латиница, ключ=значение). Ими удобно разбирать, на каком этапе ушло время. Фильтр: `adb logcat | grep auth-timing` или в Android Studio по тегу/тексту `[auth-timing]`.

| Событие | Поля | Что смотреть |
|---------|------|----------------|
| `bootstrap` | url, elapsed_ms, total_ms, success, urls_count / error | Время до первого успешного bootstrap или до перебора всех URL. |
| `google_auth_start` | event=start | Старт входа через Google. |
| `google_ui` | elapsed_ms, canceled | Время до выбора аккаунта/отмены в окне Google. |
| `google_token` | elapsed_ms | Время получения id_token от Google после выбора аккаунта. |
| `callback_start` | total_so_far_ms | Момент перед отправкой POST /auth/google/callback. |
| `post` | path, url, attempt, elapsed_ms, total_ms, status, success, error_type | Каждая попытка POST (callback, verify-code и т.д.): по какому URL, сколько заняло, итог. |
| `google_auth_done` | total_ms, callback_ms, status (success/callback_failed/dio_error/exception/canceled) | Итог входа через Google: общее время и время только на callback. |
| `email_verify_start` | email | Старт проверки кода по email. |
| `email_verify_done` | total_ms, success, status_code/error_type/exception | Итог входа по коду: общее время и результат. |

| Проверка | Где смотреть | Что значит |
|----------|----------------|------------|
| Bootstrap перед auth | Логи: `AuthService: bootstrap попытка` | Сначала приложение запрашивает `GET /api/vpn/bootstrap` для списка URL. При таймауте bootstrap — используются дефолтные URL + IP fallback. |
| URL для callback/send-code | `AppConfig.apiBaseUrl`, после bootstrap — перебор `AppConfig.apiBaseUrls` при ошибке | Таймаут на одном URL → retry на следующем (в т.ч. по IP). |
| Таймауты клиента | `connectTimeout: 20s`, `receiveTimeout: 30s` в AuthService; bootstrap 15s | Connection timeout — при недоступности API с устройства или очень медленной сети. |
| Google: id_token null | Логи: «idToken не возвращён от Google» | Неверный Client ID, SHA-1 в Console, или тип OAuth client (должен быть Android). |
| Ошибки после callback | Логи: `Google OAuth: CALLBACK FAILED` или DioException (connectionTimeout, 502, 503) | 502/503 — проблема на сервере или nginx; connectionTimeout — запрос не доходит. |
| Email: ответ send-code | 200 + `ok: true` → код отправлен. 429 → «Превышен лимит». 500 + `email_send_failed` → письмо не ушло. | На клиенте код нормализуется (trim, убираются пробелы) перед verify-code. |
| Email: verify-code | Код в запросе: `code: normalizedCode` (без пробелов). Ошибки 400/429/500 в логах. | Неверный/истёкший код, лимит попыток, или сетевая ошибка. |

---

## 4. Перекрёстная проверка

| Ситуация | Интерпретация |
|----------|----------------|
| В nginx access.log **нет** записей от IP устройства на `/api/auth/google/callback` или `/api/auth/send-code` в момент ошибки | Запрос **не доходит** до сервера (connection timeout на клиенте, сеть, блокировка, IPv6). |
| В access.log **есть** запрос, в логах API **нет** `[google-callback] ЗАПРОС ПОЛУЧЕН` | Запрос дошёл до nginx, но не до приложения (502, таймаут upstream, падение воркера). |
| В логах API **есть** `[google-callback] ЗАПРОС ПОЛУЧЕН`, дальше ошибка | Проблема в приложении: allowed_google_client_ids, JWKS, токен, БД. |
| send-code: в логах «Код создан в БД», но «Email не был отправлен» / exception | Ошибка отправки письма (SES/Postbox, квоты, неверный адрес отправителя). |
| verify-code: 400 «Неверный код» при верном коде | Проверить нормализацию кода (пробелы, тип строки) на клиенте и сравнение хеша на сервере. |

---

## 5. Частые проблемы

| Симптом | Причина | Где править |
|---------|---------|-------------|
| Connection timeout к api.granilink.com / IP | Запрос не доходит до nginx (сеть, IPv6, блокировка). | Клиент: IPv4-only HTTP client уже есть; проверить другую сеть, firewall. |
| 500 «OAuth не настроен» | `allowed_google_client_ids` пустой. | Backend: env/БД `ALLOWED_GOOGLE_CLIENT_IDS` или `google_oauth_client_ids`. |
| «Не удалось получить ключи Google OAuth» | API не может скачать JWKS с https://www.googleapis.com/oauth2/v3/certs. | Сеть сервера, proxy, firewall; при необходимости увеличить таймаут в `google_oauth_service` (сейчас 10 s). |
| Google: «idToken не возвращён от Google» | Неверный Client ID или SHA-1 для Android. | Google Cloud Console: OAuth client для Android, package name, SHA-1. |
| 429 на send-code / verify-code | Превышен rate limit по IP или email. | Подождать 1 мин или увеличить лимиты в `core/constants.py` (для теста). |
| 500 «Не удалось отправить код подтверждения» | Ошибка send_verification_email (SES/Postbox). | Логи API `[send-code]`, проверить квоты, credentials, домен отправителя. |
| 502 от nginx при callback | Upstream (API) не ответил за 60 s или упал. | Часто — долгий запрос к Google JWKS; проверить доступность googleapis.com с сервера, при необходимости увеличить `proxy_read_timeout`. |

---

## 6. Логи авторизации: есть ли за 3 месяца и где искать

**В репозитории** отдельных файлов с логами авторизации **нет**. Код пишет в стандартный Python logger (`[google-callback]`, `[send-code]`, `[verify-code]`) → вывод идёт в stdout контейнера API.

**Где могут быть следы авторизации:**

| Место | Что есть | Срок хранения |
|-------|----------|----------------|
| **Сервер: nginx access.log** | Каждый запрос к `/api/auth/google/callback`, `/api/auth/send-code`, `/api/auth/verify-code` — IP, время, метод, статус. | Зависит от ротации (часто дни/недели; за 3 месяца — только если не ротировали или есть централизованный сбор логов). |
| **Сервер: docker logs granivpn_api** | Строки с `[google-callback]`, `[send-code]`, `[verify-code]` — факт запроса, email (частично), успех/ошибка. | Обычно ограничен размером/ротацией журнала контейнера; за 3 месяца — только при настроенном сборе логов (например, в внешнюю систему). |
| **БД: users** | Поле **last_login_at** — обновляется при **успешном входе через Google** (в `auth.py` при google/callback). Для входа по email это поле в текущем коде **не обновляется**. | По `last_login_at` можно увидеть, кто последний раз успешно заходил через Google и когда. |
| **БД: auth_codes** | Записи по send-code: email, created_at, expires_at, ip_address. После успешного verify-code запись **удаляется**. | Сохраняются только активные или недавно истёкшие коды; долгая история за 3 месяца в этой таблице не накапливается. |
| **БД: admin_login_logs** | Логи входов **только в админ-панель** (успех/неуспех, IP, user_agent, причина отказа). | Для обычных пользователей приложения эта таблица **не используется**. |

**Итог:** чтобы сказать «есть ли логи авторизации за последние 3 месяца», нужен доступ к серверу (nginx access.log, docker logs) и/или к БД. По полю `users.last_login_at` можно увидеть последний успешный вход через Google по каждому пользователю; отдельной таблицы с историей входов в приложение (как у админов) нет.

---

## 7. Почему авторизация проходила (когда проходила)

Когда авторизация **успешна**, по коду это значит:

1. **Запрос дошёл до API** — nginx принял запрос (есть запись в access.log), приложение получило его (в логах API есть `[google-callback] ЗАПРОС ПОЛУЧЕН` или `[send-code] НАЧАЛО ОТПРАВКИ` / `[verify-code] НАЧАЛО ПРОВЕРКИ`).
2. **Google:** настроен `allowed_google_client_ids`, запрос к https://www.googleapis.com/oauth2/v3/certs прошёл, id_token валиден, пользователь создан/обновлён, JWT выдан.
3. **Email:** код создан в БД, письмо отправлено (SES/Postbox), при verify-code код совпал, пользователь создан/обновлён, JWT выдан.

То есть авторизация проходила, когда не было проблем **до сервера** (сеть, таймаут, IPv6) и не было ошибок **на сервере** (конфиг OAuth, JWKS, отправка письма, rate limit). По логам на сервере за нужный период можно увидеть конкретные успешные запросы (IP, время, 200 в access.log и соответствующие строки в логах API).

---

## 8. Авторизация работала недавно, перестала после изменений в коде

С этой среды **нет доступа по SSH к серверу** — проверки ниже нужно выполнять на своей машине или на сервере.

### Что проверить на сервере

1. **Когда последний раз деплоили backend/nginx**
   - `docker images granivpn_api --format "{{.CreatedAt}}"` или дата файлов в `/opt/grani/backend` на сервере.
   - Если деплой был примерно в момент, когда авторизация перестала работать — откатить образ/код на версию недельной давности и перезапустить контейнеры.

2. **Переменные окружения API (Google OAuth)**
   - В контейнере или в `/opt/grani/server-config/.env`, `/etc/grani/secrets.env`: есть ли `ALLOWED_GOOGLE_CLIENT_IDS` или `GOOGLE_OAUTH_CLIENT_IDS` / `GOOGLE_OAUTH_DEFAULT_CLIENT_ID` и не пустые ли они.
   - Если переменную удалили или переименовали — callback начнёт возвращать 500 «OAuth не настроен».

3. **Доступность Google JWKS с сервера**
   - На сервере: `docker exec granivpn_api curl -sI --connect-timeout 5 https://www.googleapis.com/oauth2/v3/certs`
   - Если запрос таймаутится или блокируется — callback будет падать с ошибкой получения ключей.

4. **Nginx и таймауты**
   - Не меняли ли недавно конфиг nginx для `location /api/` (в т.ч. `proxy_read_timeout`, `proxy_pass`). Слишком маленький таймаут может обрывать долгий callback (проверка JWKS).

5. **Логи за момент «перестало работать»**
   - Запустить `./server-config/check-backend-logs.sh` с машины с SSH.
   - В логах API искать по времени: `[google-callback] allowed_google_client_ids не настроен`, ошибки JWKS, 400/409, исключения при send-code/verify-code.

### Какие изменения в коде могли сломать авторизацию

| Область | Файлы | Что могло сломать |
|--------|--------|--------------------|
| **Клиент: HTTP и TLS** | `mobile-app/lib/core/api/ipv4_http_client.dart`, `auth_service.dart` (createHttpClient, baseUrl, таймауты) | Другой таймаут, отключение IPv4-only, смена baseUrl/пути, ошибка в connectionFactory → таймаут или 400 «plain HTTP to HTTPS». |
| **Клиент: пути и заголовки** | `auth_service.dart` (`_postWithRetryAndFallbacks`, path `/auth/google/callback`, `/auth/send-code`, Host для IP) | Неверный path, отсутствие Host при запросе по IP → 400/404 или неверный vhost на nginx. |
| **Бэкенд: конфиг Google** | `backend/core/config.py` (allowed_google_client_ids, google_oauth_*), env на сервере | Пустой список client_id → 500 «OAuth не настроен». |
| **Бэкенд: auth** | `backend/api/auth.py` (callback, send_code, verify_code) | Изменение формата запроса/ответа, удаление полей, жёсткая проверка — 400/500. |
| **Бэкенд: JWKS** | `backend/services/google_oauth_service.py` (URL, таймаут, кэш) | Недоступность googleapis.com с сервера или таймаут → ошибка при проверке id_token. |

Рекомендация: посмотреть историю коммитов за последние 1–2 недели по этим файлам (`git log --oneline -20 -- mobile-app/lib/core/api/ mobile-app/lib/services/auth_service.dart backend/api/auth.py backend/core/config.py backend/services/google_oauth_service.py`) и откатить или точечно проверить подозрительные изменения.

### Бэкенд: откуда берутся Google client_id (важно для «перестало после изменений»)

В `backend/core/config.py` свойство `allowed_google_client_ids` берёт значение по приоритету:

1. **GOOGLE_OAUTH_CLIENT_IDS** — список через запятую (поле `google_oauth_client_ids`);
2. **GOOGLE_OAUTH_DEFAULT_CLIENT_ID** — одна строка;
3. **ALLOWED_GOOGLE_CLIENT_IDS** — запасной вариант: если задан в env (через запятую), тоже используется.

Если ни один не задан или пустой → 500 «OAuth не настроен». На сервере достаточно любой из трёх переменных с корректным client id из Google Cloud Console.

---

## 9. Что можно сказать по логам

**Только по логам устройства (клиент):** нельзя однозначно сказать, «запрос не дошёл до сервера» или «сервер не ответил». Видно лишь: произошёл **connection timeout** (или другая DioException). Это согласуется и с сетевой проблемой до сервера, и с тем, что сервер долго не отвечает.

**По логам сервера (nginx + API):**

| Что смотрим | Что можно сказать |
|-------------|-------------------|
| **nginx access.log** | Запрос с IP пользователя на `/api/auth/...` в момент сбоя **есть** → запрос дошёл до nginx. **Нет** записи с этого IP в это время → запрос **не дошёл** до сервера (таймаут/сеть на стороне клиента). |
| **nginx error.log** | 502, upstream timed out, connection refused → запрос дошёл до nginx, проблема между nginx и API или таймаут ответа. |
| **Логи API** (`[google-callback]`, `[send-code]`, `[verify-code]`) | Есть «ЗАПРОС ПОЛУЧЕН» / «НАЧАЛО ОТПРАВКИ» → запрос дошёл до приложения. Дальше по строкам — ошибка конфига, JWKS, БД, отправки письма и т.д. |

**Итог:** вывод «запросы не доходят до сервера» делается **по серверным логам** (нет строк в access.log от IP пользователя). Без доступа к nginx/API логам на сервере этот вывод сделать нельзя. Скрипт `server-config/check-backend-logs.sh` нужно запускать с машины, с которой есть SSH на сервер.

---

## 10. Root cause по текущему инциденту (OnePlus)

- **Установлено:** В момент ошибки в nginx access.log **нет записей** от IP устройства по маршрутам `/api/auth/google/callback`, `/api/vpn/bootstrap` и т.д. (проверялось на сервере по логам.)
- **Вывод:** Ошибка **до сервера** — connection timeout на стороне клиента (сеть/маршрутизация/IPv6), а не поломка Google OAuth или email на бэкенде.
- **Авторизация по Google/email на сервере** при этом настроена и работает для других клиентов (по логам есть успешные 200 на bootstrap, callback и т.д.).

---

## 8. Чек-лист при обращении пользователя

1. **Есть ли запрос в nginx access.log** с его IP на `/api/auth/google/callback` или `/api/auth/send-code` в указанное время?
   - Нет → диагностика сети/клиента (таймаут, другая сеть, IPv4-only).
   - Да → смотреть статус ответа и логи API.
2. **Google:** В логах API есть `[google-callback] ЗАПРОС ПОЛУЧЕН`?
   - Нет при наличии записи в access.log → 502/таймаут upstream.
   - Да → смотреть следующую строку (allowed_google_client_ids, JWKS, 400/409).
3. **Email:** В логах есть `[send-code] ... Отправка email для <email>` и следом успех или exception?
   - Exception / email_send_failed → проверять SES/Postbox и квоты.
4. **Rate limit:** В логах «Rate limit exceeded» или ответ 429 → объяснить лимиты и подождать или ослабить для теста.

---

## 12. Ссылки на код

- **Backend auth:** `backend/api/auth.py` — маршруты `/send-code`, `/verify-code`, `/google/callback`; логи `[send-code]`, `[verify-code]`, `[google-callback]`.
- **Google OAuth:** `backend/services/google_oauth_service.py` — `verify_google_id_token`, JWKS URL, кэш ключей.
- **Конфиг Google:** `backend/core/config.py` — `allowed_google_client_ids` (из `google_oauth_client_ids` / `google_oauth_default_client_id`).
- **Rate limits:** `backend/core/constants.py` — `AUTH_SEND_CODE_RATE_LIMIT_IP/EMAIL`, `AUTH_VERIFY_CODE_RATE_LIMIT_IP/EMAIL`, период 60 с.
- **Клиент:** `mobile-app/lib/services/auth_service.dart` — `signInWithGoogle()`, `sendCode()`, `verifyCode()`, `_postWithRetryAndFallbacks`, таймауты и обработка DioException.
- **Скрипт логов на сервере:** `server-config/check-backend-logs.sh` — вывод nginx access/error и логов API для указанного интервала.

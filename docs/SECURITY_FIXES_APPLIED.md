# Применённые исправления безопасности (тестовые данные и заглушки)

## Критичные (приоритет 1)

### 1. SECRET_KEY (backend/core/config.py)
- **Было:** дефолт `grani-super-secret-key-2024-change-this-in-production`
- **Сделано:** чтение из `SECRET_KEY`; в production при дефолте или ключе с "change-this" / &lt;32 символов — **запуск блокируется** с ошибкой.
- **Production:** обязательно задать `SECRET_KEY` в env (минимум 32 символа).  
  Генерация: `python3 -c 'import secrets; print(secrets.token_urlsafe(32))'`

### 2. ADMIN_PASSWORD (backend/init_db.py)
- **Было:** дефолт `admin123`
- **Сделано:**  
  - в **production** пароль **обязателен** через `ADMIN_PASSWORD`; при отсутствии — выход с ошибкой;  
  - в **development** при отсутствии `ADMIN_PASSWORD` используется `admin123`.
- **Production:** задать `ADMIN_PASSWORD` (и при необходимости `ADMIN_EMAIL`) перед `init_db`.

### 3. SSH‑пароли (хардкод удалён)
- **Было:** пароль `c75aZ83oIpx0` в 17+ файлах (скрипты, create_server_direct, add_server_to_db и др.).
- **Сделано:** все обращения переведены на **`SSH_PASSWORD`** (или `SERVER_PASSWORD` в части shell‑скриптов).  
  При отсутствии переменной скрипты завершаются с ошибкой.
- **Затронутые области:**  
  - `backend/create_server_direct.py`  
  - `backend/scripts/`: test_ssh_connection, setup_xray_*, fix_*, check_*, debug_*, verify_*, update_wg_config_rules, setup_vpn_server и др.  
  - `scripts/add_server_to_db.py`  
  - `scripts/test_server_connection.sh` (пароль: 3‑й аргумент или `SSH_PASSWORD`)  
  - `mobile-app/android/scripts/check_server_setup.sh` (`SSH_PASSWORD` / `SERVER_PASSWORD`)

---

## Важные (приоритет 2)

### 4. Тестовые email
- **Было:** `rail.tamaew@gmail.com` по умолчанию во множестве скриптов.
- **Сделано:**  
  - везде используются **`--email`** и/или **`TEST_EMAIL`**;  
  - при отсутствии и email, и `TEST_EMAIL` скрипты выходят с ошибкой.
- **Скрипты:** vpn_tester, test_all_protocols, export_client_configs, quick_test_xray, force_disconnect_and_connect_xray, check_client_logs_status, check_xray_logs, check_user_connection_status, diagnose_xray_connection, fix_xray_connection_issues, create_trial_subscription, test_registration_flow, check_user_token, test_token_servers; create_owner/create_owner_auto — `OWNER_EMAIL`.

### 5. Тестовые URL (localhost:8000)
- **Было:** жёстко `http://localhost:8000` в config и скриптах.
- **Сделано:**  
  - **config:** `api_url` читается из **`API_URL`**, по умолчанию `http://localhost:8000` только для dev;  
  - скрипты используют **`--api-url`** и/или **`API_URL`**; при необходимости — `API_BASE_URL`/`api_base`.
- **Production:** задать `API_URL` (например `https://api.granilink.com`).

### 6. Окружение ENV
- **Было:** дефолт `development`.
- **Сделано:** явно **`ENV=production`** в production.  
  В production дополнительно действуют проверки: `SECRET_KEY`, `DATABASE_URL`, `API_URL` (см. ниже).

### 7. DATABASE_URL
- **Было:** дефолтный URL с паролем `granivpn_password`.
- **Сделано:**  
  - в **production** при использовании дефолтного URL (с `granivpn_password`) **запуск приложения блокируется**;  
  - необходимо задать **`DATABASE_URL`** в env.

---

## Проверки при старте (приоритет 3)

### Блокировка production с дефолтами (backend/core/config.py)
Добавлен `model_validator` для **production**:
- **SECRET_KEY:** не дефолт, нет "change-this", длина ≥ 32.
- **DATABASE_URL:** не должен содержать `granivpn_password`.
- **API_URL:** не должен быть `http://localhost:8000`.

При нарушении приложение не запускается, в лог выводится сообщение с указанием, что нужно задать в env.

---

## Переменные окружения

| Переменная       | Назначение                    | Обязательна в production |
|------------------|-------------------------------|---------------------------|
| `ENV`            | `development` / `production`  | да (`production`)         |
| `SECRET_KEY`     | JWT / сессии                  | да                        |
| `DATABASE_URL`   | Подключение к БД              | да                        |
| `API_URL`        | Базовый URL API               | да                        |
| `ADMIN_EMAIL`    | Email админа (init_db)        | по желанию                |
| `ADMIN_PASSWORD` | Пароль админа (init_db)       | да                        |
| `SSH_PASSWORD`   | SSH‑пароль серверов           | да для скриптов с SSH     |
| `TEST_EMAIL`     | Тестовый email в скриптах     | при запуске скриптов      |
| `OWNER_EMAIL`    | Email владельца (create_owner) | при создании owner        |
| `OWNER_PASSWORD` | Пароль владельца              | при create_owner_auto     |

---

## Рекомендации

1. **Production:** все секреты и URL задавать через env (или secrets manager), не использовать дефолты из кода.  
2. **Скрипты:** перед запуском выставлять `SSH_PASSWORD`, при необходимости `TEST_EMAIL` и `API_URL`.  
3. **Проверка:** при `ENV=production` убедиться, что приложение стартует только с заданными `SECRET_KEY`, `DATABASE_URL`, `API_URL`.

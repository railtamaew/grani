# Проверка Boring HTTPS в приложении от и до

Чек-лист полной проверки протокола Boring HTTPS в мобильном приложении (без выхода трафика в интернет — gateway пока отдаёт пустой ответ).

---

## 1. Подготовка backend

### 1.1. URL gateway для эмулятора и устройства

- **Эмулятор Android:** хост = `10.0.2.2`, порт backend = например `8799`.  
  Итог: `BORING_HTTPS_GATEWAY_URL=http://10.0.2.2:8799/api/vpn/tunnel`
- **Реальное устройство в той же сети:** подставьте IP хоста (например `192.168.1.100:8799`).

### 1.2. Запуск backend

```bash
cd /opt/grani/backend

# Эмулятор:
export BORING_HTTPS_GATEWAY_URL="http://10.0.2.2:8799/api/vpn/tunnel"
uvicorn main:app --host 0.0.0.0 --port 8799

# Или одна строкой:
BORING_HTTPS_GATEWAY_URL="http://10.0.2.2:8799/api/vpn/tunnel" uvicorn main:app --host 0.0.0.0 --port 8799
```

Убедитесь, что в логах нет ошибок и сервер слушает на 8799.

---

## 2. Подготовка приложения

### 2.1. API base URL

Приложение должно ходить на тот же backend (для эмулятора — хост `10.0.2.2`, порт 8799).

- **Через dart-define при сборке:**
  ```bash
  flutter build apk --dart-define=API_BASE_URL=http://10.0.2.2:8799/api
  ```
- Или в коде/конфиге dev-сборки задать `API_BASE_URL` так, чтобы базовый URL был `http://10.0.2.2:8799/api` (для эмулятора).

### 2.2. Сборка и запуск

```bash
cd /opt/grani/mobile-app

# Debug на эмуляторе (если API уже указывает на 10.0.2.2:8799):
flutter run

# Или с явным API:
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8799/api
```

---

## 3. Чек-лист проверки в приложении

| # | Шаг | Ожидаемый результат |
|---|-----|----------------------|
| 1 | Открыть приложение | Экран входа или главный экран |
| 2 | Войти (email + код или тестовый аккаунт) | Успешная авторизация |
| 3 | Обновить список серверов (pull-to-refresh при необходимости) | Список серверов загружен |
| 4 | Выбрать любой сервер | Сервер выделен |
| 5 | Открыть выбор протокола (кнопка протокола / «Протоколы») | В списке есть **Boring HTTPS** |
| 6 | Выбрать **Boring HTTPS** | Протокол переключился на Boring HTTPS |
| 7 | Нажать «Подключиться» / Connect | Идёт процесс подключения (индикатор) |
| 8 | Дождаться окончания | Подключение успешно: иконка VPN, статус «Подключено» (трафик в интернет пока не идёт — gateway возвращает пустой ответ) |
| 9 | Нажать «Отключиться» | VPN отключается без ошибок |

---

## 4. Что проверить при ошибках

- **«Сервер не поддерживает протокол»** — backend запущен без `BORING_HTTPS_GATEWAY_URL` или переменная пустая. Перезапустите backend с переменной из п. 1.2.
- **Boring HTTPS не в списке протоколов** — у выбранного сервера в ответе API нет `boring_https` в `supported_protocols`. Проверьте, что backend действительно отдаёт `boring_https` (при заданном `BORING_HTTPS_GATEWAY_URL`).
- **Таймаут / ошибка сети при подключении** — приложение не достучится до API или до gateway. Для эмулятора проверьте: API base = `http://10.0.2.2:8799/api`, в конфиге connect ответ содержит `endpoint_url: http://10.0.2.2:8799/api/vpn/tunnel`.
- **Ошибка после «Применяем конфигурацию»** — смотрите логи Android (`adb logcat`, фильтр по `GraniVpnService` или `BoringHttps`): не удалось создать TUN, не прошёл health check (gateway недоступен с устройства) или другая ошибка в адаптере.

---

## 5. Быстрая проверка API с хоста (без приложения)

Убедиться, что backend отдаёт протокол и конфиг:

```bash
# Токен получите после логина (из приложения или через POST /api/auth/verify-code).
TOKEN="ваш_jwt_токен"

# Список серверов — в каждом должен быть boring_https в supported_protocols:
curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:8799/api/vpn/servers" | jq '.[0].supported_protocols'

# Connect с boring_https (device_id и server_id подставьте свои):
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"server_id":1,"device_id":"test-device-123","protocol":"boring_https"}' \
  "http://127.0.0.1:8799/api/vpn/connect" | jq '.config, .success'
```

Ожидаемо: `success: true`, в `config` — `protocol`, `endpoint_url`, `headers`, `sni`.

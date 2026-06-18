# Отчёт: анализ проблемы повторного подключения VPN (нет интернета после reconnect)

**Дата:** 17.02.2026  
**Тема:** Повторное подключение Xray — приложение показывает «подключено», но интернет не работает.

---

## 1. Split-tunnel (API-запросы в обход VPN)

### Текущее состояние

Разделение трафика настроено корректно:

- Правила Xray отправляют `api.granilink.com` и `domain:granilink.com` в outbound `direct`
- Реализовано в:
  - `mobile-app/lib/protocols/xray/models/xray_config.dart` (строки 634–642)
  - `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/XrayConfig.kt` (строки 172–182)

### Возможная проблема

**Правило `domain` может не срабатывать, если подключение идёт по IP.**

Когда HTTP-клиент (Dio) подключается к `api.granilink.com`:

1. Сначала резолвит домен в IP (например, 159.223.199.122)
2. Подключается к IP:443

В SOCKS-запросе от tun2socks целевой хост передаётся уже как IP, без домена. В этом случае правило `domain` в маршрутизации Xray не совпадает — трафик идёт в `proxy` (через VPN), а не в `direct`.

**Последствия:** API-запросы (ConnectionLogger, refreshServers, GET /config и т.п.) могут идти через VPN. Если туннель нерабочий (например, из‑за неверного UUID), такие запросы будут получать RST или таймаут.

**Рекомендация:** Добавить sniffing во inbound SOCKS (для извлечения SNI из TLS) и/или правило `ip` для IP API-сервера (если IP известен и относительно стабилен).

---

## 2. Причина «подключено, но нет интернета» при reconnect

### Последовательность событий (по логам)

**Первое подключение (09:28:04):**

- `create-client` возвращает `client_id: vless_60_1`, UUID: `cae4d39a-645f-403b-8a8b-7eab2690652d`
- VPN поднимается, трафик идёт, проверка по статистике проходит

**Отключение (09:28:47):**

```
Ошибка удаления Xray клиента на сервере: TimeoutException after 0:00:04.000000
Xray client_id сохранён в кэш для 1_xray_vless
```

- DELETE `/vpn/xray/client/vless_60_1` упирается в таймаут 4 секунды
- Неизвестно, успел ли сервер удалить клиента или нет
- `client_id` сохраняется в кэш приложения

**Повторное подключение (09:28:53):**

- `client_id восстановлен из кэша` → используется быстрый путь GET `/config/vless_60_1`
- GET `/config` возвращает 200 с **другим UUID:** `4b745911-a27b-4563-b28d-e73d525263dd` (вместо `cae4d39a...`)

### Корневая причина

В `backend/services/xray_manager.py` метод `_generate_client_json_config`:

1. Сначала вызывает `_resolve_client_uuid_from_server_config(client_id, server, protocol)` — попытка взять UUID клиента из конфига Xray на сервере по SSH
2. Если `_resolve` возвращает `None`, подставляется **новый случайный UUID** (`uuid.uuid4()`)

```python
# backend/services/xray_manager.py, строки 1396–1410
if not uuid_str:
    uuid_str = self._resolve_client_uuid_from_server_config(client_id, server, protocol)
    if not uuid_str:
        parts = client_id.split('_')
        if len(parts) >= 3:
            uuid_str = str(uuid.uuid4())  # НОВЫЙ UUID!
```

`_resolve_client_uuid_from_server_config` возвращает `None`, если:

- SSH/remote_manager недоступны
- Клиент не найден в конфиге (удалён или не совпадает по email)
- Ошибка при чтении конфига по SSH
- Исключение при разборе конфига

**Последствие:** приложение получает конфиг с **новым** UUID, которого нет в inbound на Xray-сервере. Сервер отклоняет соединения по этому UUID → туннель «поднят», но трафик не проходит.

### Сценарии отказа _resolve

1. **Таймаут disconnect:**  
   DELETE мог не успеть или не выполниться, клиент мог быть удалён позже, а может и остаться. В любом случае при следующем GET /config состояние на сервере может быть непредсказуемым.

2. **Клиент удалён:**  
   Если disconnect всё же отработал, клиент удалён. `_resolve` не находит его → генерируется новый UUID → клиент не проходит валидацию на Xray.

3. **SSH/чтение конфига:**  
   Ошибки SSH, таймауты, исключения → `_resolve` возвращает `None` → снова новый UUID.

4. **Несовпадение email:**  
   Email ищется по `device_id` из `client_id`. При несовпадении формата или device_id клиент не находится.

---

## 3. Связь с предыдущей проблемой

Из комментария в коде (`xray_config.dart:636`):

> «Без этого второй connect использует кэш, запросы идут через VPN и получают RST.»

При reconnect:

1. Используется кэш `client_id` и быстрый путь GET /config.
2. Если GET /config возвращает конфиг с **неверным** UUID (из‑за `uuid4()` fallback), туннель поднимается, но трафик блокируется.
3. API-запросы идут через этот же туннель (особенно если правило domain не срабатывает из‑за подключения по IP).
4. В итоге: RST, таймауты и ощущение «нет интернета».

---

## 4. Рекомендации

### 4.1. Backend: надёжный resolve UUID для GET /config

- Не использовать `uuid.uuid4()` как fallback при GET /config.
- Если `_resolve_client_uuid_from_server_config` возвращает `None` — не отдавать конфиг, а возвращать 404 или явную ошибку и предлагать клиенту вызвать `create-client` заново.

### 4.2. Мобильное приложение: fallback на create-client при неуверенности

- При GET /config 404 или пустом ответе — уже есть fallback на `create-client` (реализовано).
- Дополнительно: при таймауте disconnect **очищать кэш** `client_id` и не использовать быстрый путь GET /config, а сразу идти в `create-client`.
- Можно ввести флаг «disconnect мог не завершиться» и в этом случае всегда использовать `create-client`.

### 4.3. Disconnect API

- Увеличить таймаут DELETE (сейчас 4 с) или сделать retry.
- Убедиться, что DELETE идёт до полного отключения VPN, чтобы запрос не обрывался из‑за разрыва туннеля.

### 4.4. Split-tunnel: domain vs IP

- Включить sniffing во inbound SOCKS, чтобы Xray мог использовать SNI для маршрутизации.
- Либо добавить правило `ip` для IP `api.granilink.com`, если IP относительно стабилен.

---

## 5. Выводы

| Проблема | Причина | Критичность |
|----------|---------|-------------|
| Нет интернета после reconnect | GET /config при неудачном `_resolve` возвращает конфиг с новым UUID; сервер не принимает трафик | **Высокая** |
| Таймаут disconnect | DELETE клиента не успевает за 4 с; состояние сервера становится неочевидным | **Средняя** |
| API через туннель | Подключение по IP; правило `domain` не срабатывает; трафик идёт через proxy | **Средняя** |
| Fallback на `uuid4()` | Генерирует невалидный конфиг вместо перехода на create-client | **Высокая** |

**Основной источник проблемы:** неотказоустойчивый fallback `uuid.uuid4()` в `_generate_client_json_config`, когда не удаётся получить реальный UUID клиента с сервера.

---

## 7. Реализованные исправления (17.02.2026)

### 7.1. Упрощённая архитектура reconnect

**Mobile (vpn_service.dart):**
- **Полный конфиг в SecureStorage** — после успешного connect Xray-конфиг сохраняется в SecureStorage (`xray_config_${serverId}_${protocol.apiValue}`).
- **Reconnect без API** — при reconnect сначала проверяются SecureStorage и CacheService. Если конфиг найден — применяется напрямую, без вызовов API.
- **Fallback на create-client** — при отсутствии локального конфига вызывается только `create-client`; путь GET /config удалён.
- **Удалён _xrayClientIdCache** — кэш client_id больше не используется.

**Backend (xray_manager.py):**
- **Убран fallback uuid4()** — при неудачном `_resolve_client_uuid_from_server_config` метод возвращает `None`, не генерирует новый UUID.

**Backend (vpn_operations_service.py):**
- **get_xray_config** — при `json_config is None` возвращает 404.
- **get_or_create_connection** — при 404 от get_xray_config fallback на create_xray_client.

### 7.2. Итоговый reconnect-flow

1. **Reconnect с локальным конфигом:** SecureStorage → CacheService → применение → VPN без API.
2. **Reconnect без кэша:** create-client → сохранение конфига → применение → VPN.
3. **Backend GET /config 404:** клиент не найден на сервере → create-client.

### 7.3. Рекомендуемое тестирование

- [ ] connect → disconnect → reconnect (должен брать из SecureStorage)
- [ ] reconnect после перезапуска приложения
- [ ] reconnect после смены сети
- [ ] первый connect и create-client без регрессий

---

## 6. Инструкция: как получить и проанализировать логи с серверов

### 6.1. VPN-сервер (Xray, WireGuard) — 45.12.132.94 (HU-BUD-01)

**Через скрипт (требуется SSH):**

```bash
# Вариант 1: с БД (если сервер в таблице servers и есть ssh_key_content)
cd /opt/grani
PYTHONPATH=/opt/grani/backend python3 backend/scripts/fetch_server_logs.py --name HU-BUD-01

# Вариант 2: без БД, с явным ключом
PYTHONPATH=/opt/grani/backend python3 backend/scripts/fetch_server_logs.py \
  --ip 45.12.132.94 --ssh-key-path /path/to/key.pem

# Вариант 3: ключ через переменную окружения
SSH_KEY_CONTENT="$(cat /path/to/key.pem)" PYTHONPATH=/opt/grani/backend python3 backend/scripts/fetch_server_logs.py --ip 45.12.132.94
```

**Что смотреть в логах Xray при reconnect-проблеме:**

- **access.log** — UUID клиентов, принятые подключения, успешные/неуспешные туннели.
- **error.log** — отказы в подключении, таймауты, `failed to find an available destination`, `context canceled`.
- **journalctl -u xray** — рестарты Xray, обновление конфига, ошибки при применении inbound/clients.

**Интерпретация при гипотезе «клиент: race / ошибка при повторном применении конфига»:**

| Что видим | Вывод |
|-----------|-------|
| Нет новых записей в access.log с UUID клиента после reconnect | Трафик до сервера не доходит → клиент: конфиг не применён, race, туннель не поднят |
| Есть новые записи, но запросы к api.granilink.com таймаутят | Возможна маршрутизация (direct vs proxy) или другая причина |
| error.log: `invalid user`, отказы по UUID | Сервер отклоняет подключение (неверный UUID/конфиг) |
| journalctl: reload/рестарт во время reconnect | Мог повлиять порядок операций на сервере |

**Ручной доступ по SSH:**

```bash
ssh -i /path/to/key.pem root@45.12.132.94

# Xray
journalctl -u xray -n 200 --no-pager
tail -n 200 /var/log/xray/access.log
tail -n 200 /var/log/xray/error.log

# WireGuard
journalctl -u wg-quick@wg0 -n 150 --no-pager
```

### 6.2. API-сервер (grani-api)

Логи API помогут понять:
- пришёл ли GET /config и какой client_id;
- были ли create-client / delete-client и их результаты;
- ошибки ConnectionOrchestrator / XrayManager.

**Варианты (зависит от деплоя):**

```bash
# systemd
journalctl -u grani-api -n 500 --no-pager

# Файл
tail -n 500 /var/log/grani/api.log
```

### 6.3. БД: client_logs (логи с мобильного приложения)

Client_logs пишутся при отправке логов через `POST /api/vpn/logs/send`. Там есть:
- `event_type` (connection_start, connection_end, connection_error и т.д.);
- `client_id`, `server_id`, `protocol`;
- `connection_duration_ms`, `error_details` (JSON: network_type, stage).

**Скрипт (требуется доступ к БД):**

```bash
cd /opt/grani
PYTHONPATH=/opt/grani/backend python3 backend/scripts/check_client_logs_status.py user@example.com [device_id]
```

### 6.4. Ограничение локального окружения

При запуске `fetch_server_logs.py --name HU-BUD-01` без настроенной БД и SSH:
- БД: `connection to server at "localhost", port 5432 failed: password authentication failed` — нужны корректные credentials в `.env` или переменных окружения.
- SSH: для прямого вызова с `--ip` нужен `--ssh-key-path` или `SSH_KEY_CONTENT` / `SSH_PASSWORD`.

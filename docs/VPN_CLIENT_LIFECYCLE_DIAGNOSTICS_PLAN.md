# План разбора: сворачивание → смена PID → «другой протокол» → быстрый connect → провал Speedtest

**Цель:** по логам Docker (Nginx/API/Celery), БД и (при необходимости) ноды **HU-BUD-01** отделить **внутренние конфликты клиента** (процесс, UI, кэш, политика логов) от **блокировок оператора / деградации API / проблем data-plane на сервере**.

**Имена контейнеров** (см. `server-config/docker/docker-compose.yml`): `granivpn_nginx`, `granivpn_api`, `granivpn_celery`, `granivpn_postgres`, `granivpn_redis`. Общая сеть: `granivpn_network`.

---

## 0. Чеклист одного инцидента (порядок работ)

Готовые шаги в репозитории: каталог **[`scripts/diagnostics/`](../scripts/diagnostics/)** ([README](../scripts/diagnostics/README.md])) — съём logcat, Docker-окно, SQL по пользователю, разбор logcat по ключевым словам; нода — **[`backend/scripts/diagnostics_hu_bud_data_plane.py`](../backend/scripts/diagnostics_hu_bud_data_plane.py)** (read-only).

1. Зафиксировать **UTC-время** окна (от пользователя + смещение) и **email** / `user_id`.
2. Снять **logcat** с телефона сразу после воспроизведения (`adb logcat -d -v threadtime`) или **`scripts/diagnostics/capture_client_incident.sh`** (переменные `USER_EMAIL`, `INCIDENT_START_UTC`, `INCIDENT_END_UTC`; опция `--dumpsys`).
3. **Docker:** Nginx access → API → Celery за то же окно (§2) или **`scripts/diagnostics/docker_correlation_window.sh --since … [--until …]`**.
4. **Postgres:** пользователь, устройства (UUID), `client_logs` (§3) или **`scripts/diagnostics/postgres_client_logs_timeline.sh`**.
5. Если API даёт конфиг, а «интернет» нет — **нода** по §4 (только через ключ из БД, см. правила доступа).
6. Свести в **матрицу §8** и сформулировать вывод; по сохранённому logcat — **`scripts/diagnostics/logcat_protocol_matrix.sh`**.

---

## 1. Корреляция идентификаторов

| Сигнал | Где | Интерпретация |
|--------|-----|----------------|
| **PID** | logcat, `adb bugreport` | Новый PID = **новый процесс** (краш, OOM, kill). Не путать с UUID устройства. |
| **`device_id` (строка UUID)** | logcat, таблица `devices.device_id`, тело POST логов | Должен быть **стабилен** между рестартами процесса. Смена без переустановки → storage / логика `_loadDeviceId` / дубликаты в БД. |
| **`connection_session_id`** | logcat, `client_logs.error_details`, API | **Новый на каждый connect** — штатно (`VpnService`: timestamp + random). |
| **Протокол** | logcat, `client_logs.protocol` | См. §6 и строки `restore_selection` / `persist_ui_selection`. |
| **Быстрый connect** | logcat `xray_cache_hit` | Кэш конфига ≠ гарантия рабочего интернета. |

В таблице **`client_logs`** поле `device_id` — это **FK на `devices.id` (integer)**, не строка UUID. Для поиска по UUID всегда делайте `JOIN devices`.

---

## 2. Docker: Nginx, API, Celery

Рабочая директория на сервере с репозиторием: обычно `/opt/grani`, compose: `server-config/docker/docker-compose.yml`. Доп. контекст: `server-config/OPS.md`.

### 2.1. Nginx — access/error

На хосте логи смонтированы в **`/opt/grani/logs/docker-nginx`** (создать каталог до первого `up`, см. комментарий в compose). Внутри контейнера: `/var/log/nginx`.

```bash
# Пример: последние строки access за сессию
grep -E 'session/prepare|/vpn/logs/send|/health' /opt/grani/logs/docker-nginx/access.log | tail -200

# Или через контейнер + stdout (если в nginx.conf продублировано в stdout)
docker logs granivpn_nginx --since "2026-04-24T12:00:00" --until "2026-04-24T13:00:00" 2>&1 | tail -300
```

Искать: **статус**, время ответа (`rt=` / upstream), путь **`POST .../api/vpn/session/prepare`**, **`POST .../api/vpn/logs/send`**, **`GET .../health`**. Коррелировать с **X-Request-ID**, если он пишется в access-формате.

### 2.2. API

```bash
docker logs granivpn_api --since "2026-04-24T12:00:00" --until "2026-04-24T13:00:00" 2>&1 \
  | grep -E 'session/prepare|user_id|req_id|X-Request-ID|500|422' | tail -400
```

Стабильные **200** на `session/prepare` при провале Speedtest означают лишь: **контрольная плоскость и выдача JSON-конфига** в этот момент не «легли» — **не** доказывают рабочий общий интернет через VLESS.

### 2.3. Celery (сохранение `client_logs`)

Задача: `vpn.save_client_logs` (см. `backend/services/celery_app.py`, `backend/services/tasks/client_logs_tasks.py`).

```bash
docker logs granivpn_celery --since "2026-04-24T12:00:00" --until "2026-04-24T13:00:00" 2>&1 \
  | grep -iE 'save_client_logs|client_log|error|Traceback' | tail -200
```

Если в БД **нет** событий, а на клиенте POST уходил — смотреть **401**, отказ Celery, исключения в воркере.

---

## 3. PostgreSQL (`granivpn_postgres`)

```bash
docker exec -it granivpn_postgres psql -U granivpn_user -d granivpn
```

### 3.1. Пользователь и устройства (строковый UUID)

```sql
SELECT u.id AS user_id, u.email,
       d.id AS device_row_id, d.device_id AS device_uuid, d.name, d.is_active, d.updated_at
FROM users u
JOIN devices d ON d.user_id = u.id
WHERE u.email = 'USER_EMAIL_HERE'
ORDER BY d.updated_at DESC;
```

Много строк с **одним** `device_uuid` или частая смена UUID у одного пользователя — разбор цепочки **prepare / device_manager** (бэкенд), не только клиент.

### 3.2. `client_logs` по пользователю и времени

```sql
SELECT cl.id, cl.created_at, cl.event_type, cl.protocol, cl.message,
       cl.error_details::text AS details,
       d.device_id AS device_uuid
FROM client_logs cl
JOIN devices d ON d.id = cl.device_id
JOIN users u ON u.id = cl.user_id
WHERE u.email = 'USER_EMAIL_HERE'
  AND cl.created_at BETWEEN '2026-04-24 12:20:00+00' AND '2026-04-24 13:00:00+00'
ORDER BY cl.created_at;
```

Полезные `event_type`: `connectivity_probe`, `connection_success`, `connection_start`, `connection_error`, `protocol_error`, `traffic_first_seen`. В **`error_details`** часто есть `public_*`, `api_*`, `connection_session_id` (см. `backend/api/client_logs.py`).

---

## 4. VPN-нода HU-BUD-01 (45.12.132.94) — только штатный доступ из кода

**Где ключ:** PostgreSQL, таблица **`servers`**, запись **HU-BUD-01** (`ssh_host`, `ssh_port`, `ssh_user`, **`ssh_key_content`** PEM, `ssh_password` = NULL, `ssh_key_path` = NULL).

**Как ходить на SSH в коде:** только через **`RemoteVPNManager.get_ssh_config(server)`** — см. `backend/services/remote_vpn_manager.py`. Пароль из env для этой ноды **не** подставляется, если в БД задан ключ.

**Как агенту запускать с рабочей машины с БД:** поднять окружение с **`DATABASE_URL`**, затем скрипты/задачи, которые уже используют **`RemoteVPNManager`** (пример из правил проекта):

```bash
cd /opt/grani/backend && PYTHONPATH=/opt/grani/backend python3 scripts/setup_hungary_server.py
```

**Запрещено:** вставлять в ответы/доки **`ssh_key_content`**, искать пароль для HU-BUD-01, логировать приватный ключ.

**На ноде после установления SSH-сессии** (типовой деплой Xray как systemd-unit **`xray`**):

- **Unit:** `systemctl is-active xray`, `systemctl status xray`, `journalctl -u xray --no-pager -n 120`.
- **Конфиг:** `/usr/local/etc/xray/config.json`.
- **Логи:** `/var/log/xray/access.log`, `/var/log/xray/error.log`.
- **Порты:** смотреть `ss -tlnp` (часто **4443** / **8443** / **2053** / **443** / **10085** — сверять с `config.json` и выдачей API).

За окно инцидента: статус процесса, перезапуски unit, ошибки TLS/Reality в `error.log`. Цель: совпадает ли **пик переподключений клиента** с ошибками на ноде; виден ли **трафик** на ожидаемом inbound.

Автоматизация (только чтение, ключ из БД): `cd /opt/grani/backend && PYTHONPATH=/opt/grani/backend python3 scripts/diagnostics_hu_bud_data_plane.py` (опции `--server-name`, `--journal-lines`).

---

## 5. Клиент: logcat (PID, «само свернулось», протокол)

```bash
adb logcat -d -v threadtime > repro_$(date -u +%Y%m%d_%H%M%S)_utc.txt
```

**Обязательные цепочки:**

| Тема | grep / ключевые слова |
|------|------------------------|
| Смерть процесса | `FATAL`, `AndroidRuntime`, `DEBUG`, `tombstone`, `libc` |
| Убийство OOM | `lowmemorykiller`, `am_kill`, `ActivityManager`, `died` |
| Приложение | `com.granivpn.mobile`, `flutter`, `VpnService`, `GraniVpnService` |
| VPN / Xray | `CONNECTIVITY_PROBE`, `session_prepare_trace`, `xray_`, `GoLog`, `libXray` |
| Выбор протокола (после правок клиента) | `persist_ui_selection`, `restore_selection`, `selectProtocol`, `selectServer` |
| Второй движок Flutter | `FlutterEngine`, `FlutterJNI` |

**«Само свернулось»:** в коде приложения **`moveTaskToBack`** не используется как типовой путь — чаще **системный диалог** (VPN permission), **другое Activity поверх**, **краш** или **kill**. В момент repro полезен `adb shell dumpsys activity activities | head -80` (вручную).

---

## 6. Почему «протокол уже не тот» (код + текущее исправление)

1. **Дефолт в памяти:** при создании `VpnService` стартовый протокол — **`xrayReality`** (`_selectedProtocol` в `mobile-app/lib/services/vpn_service.dart`).
2. **После успешного connect** по-прежнему вызывается **`_saveLastConnectedSelection()`** — сохраняет сервер+протокол.
3. **Дополнительно сделано:** при смене в UI вызывается **`_persistUserUiSelectionToStorage`** из **`selectProtocol`** и **`selectServer`** — те же ключи `last_connected_server_id` / `last_connected_protocol`, чтобы **рестарт процесса до успешного connect** не сбрасывал выбор.
4. **Восстановление** при `refreshServers`, если сервер не выбран: **`_restoreLastConnectedSelection()`** — в логах явно:
   - `restore_selection: ok source=storage_exact …` — протокол из storage совпал с `supportedProtocols`;
   - `restore_selection: ok source=fallback_best …` — строка из storage не подошла → **`_findBestProtocol`** (другой протокол в UI — ожидаемо по логам);
   - `restore_selection: skip …` — нет данных или сервер из storage отсутствует в списке.

**Быстрый connect** после открытия приложения часто совпадает с **`xray_cache_hit`** / кэшем `xray_config_{serverId}_{protocol}` — это **не** доказательство рабочего Speedtest.

---

## 7. Speedtest

- Смотреть **`connectivity_probe`** в logcat (`[CONNECTIVITY_PROBE]` на Android) и строки **`public_*` / `api_*`** в `client_logs`, если доехали до БД.
- В **GoLog** Xray: куда ушёл запрос speedtest — **`proxy`** vs **`direct`**, таймауты, `dialing TCP`.

---

## 8. Матрица: наблюдение → гипотеза → что проверить

| Наблюдение | Гипотеза | Проверка |
|------------|----------|----------|
| Новый PID, холодный старт в logcat | Рестарт процесса | FATAL / OOM / `am_kill` |
| Тот же UUID в `devices`, новый `connection_session_id` | Норма: новый connect | Логи connect |
| Другой UUID без переустановки | Storage / `_loadDevice_id` / дубликаты устройств | БД `devices` + logcat `_loadDeviceId` |
| `restore_selection … source=fallback_best` | Протокол из storage не в `supportedProtocols` | API список серверов + storage |
| `restore_selection: skip … stored_server_not_in_list` | Список серверов изменился | API + кэш клиента |
| API 200 prepare, probe public fail, speedtest fail | Data-plane / MTU / маршрутизация на ноде | §4 + probe |
| Нет строк в `client_logs` | Celery / 401 / политика flush на клиенте | §2.3 + логи приложения |

---

## 9. Решения (что уже сделано в репозитории и что дальше)

**Уже в коде:**

- Сохранение выбора сервера/протокола **при смене в UI** (`_persistUserUiSelectionToStorage` в `selectProtocol` / `selectServer`).
- Явные логи **`restore_selection`** / **`persist_ui_selection`** для разбора «почему другой протокол».
- Ранее: ослабление политики отправки **`connectivity_probe`** в фоне, мульти-URL post-connect probe, clamp MTU для Xray, отказ от лишнего **FlutterEngine** в FCM background на Android (см. историю коммитов / `push_notification_service.dart`).

**Рекомендовано отдельно (по приоритету):**

1. **Crashlytics** (или аналог) + при желании событие `cold_start` в `client_logs` — связать смену PID со стектрейсом.
2. **Сервер:** контроль дублей `devices` на prepare ([`backend/application/services/device_manager.py`](../backend/application/services/device_manager.py), тесты `backend/tests/test_device_resolve.py`) — меньше путаницы в лимитах и логах.
3. **Нода:** при стабильном паттерне «API health OK, публичный интернет fail» — отдельный runbook по MTU/Reality/порту (вне этого документа).

---

## 10. Быстрый шпаргорг команд

```bash
# Postgres одной строкой
docker exec granivpn_postgres psql -U granivpn_user -d granivpn -c "SELECT id,email FROM users WHERE email='USER_EMAIL_HERE';"

# API за последний час (подправить время)
docker logs granivpn_api --since 1h 2>&1 | grep -i prepare | tail -50

# Celery
docker logs granivpn_celery --since 1h 2>&1 | grep -i client_log | tail -50

# Сбор инцидента (logcat + manifest)
USER_EMAIL='user@example.com' INCIDENT_START_UTC='2026-04-24T12:20:00Z' \
  /opt/grani/scripts/diagnostics/capture_client_incident.sh

# Docker за окном
/opt/grani/scripts/diagnostics/docker_correlation_window.sh --since "2026-04-24T12:00:00" --until "2026-04-24T13:00:00"

# Postgres timeline по email
/opt/grani/scripts/diagnostics/postgres_client_logs_timeline.sh 'user@example.com' \
  '2026-04-24 12:20:00+00' '2026-04-24 13:00:00+00'

# Logcat → матрица ключевых слов
/opt/grani/scripts/diagnostics/logcat_protocol_matrix.sh ./vpn_incident_capture_*/logcat_threadtime.txt

# Нода HU-BUD-01 (read-only)
cd /opt/grani/backend && PYTHONPATH=/opt/grani/backend python3 scripts/diagnostics_hu_bud_data_plane.py
```

---

Пути unit/config/log на ноде сверены с типовым деплоем и скриптом **`backend/scripts/server_diagnostic_quick.py`**; при отличии фактического сервера — поправить локальный runbook.

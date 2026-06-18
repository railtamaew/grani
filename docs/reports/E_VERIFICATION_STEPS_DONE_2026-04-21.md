# Выполнение пунктов E) проверки (2026-04-21)

## 1) SQL: `device_id` и активность

Выполнено в контейнере **`granivpn_postgres`**:

```sql
SELECT id, user_id, device_id, is_active, vpn_client_id, current_server_id, vpn_protocol, created_at
FROM devices
WHERE device_id = '3e54f374-84a3-4f3a-8d3c-64a482d2ac83'
ORDER BY is_active DESC NULLS LAST, id;
```

**Результат:**

| id  | user_id | device_id | is_active | vpn_client_id   | current_server_id | vpn_protocol | created_at |
|-----|---------|-----------|-----------|-----------------|---------------------|--------------|------------|
| 162 | 23      | 3e54f374-… | **t**     | reality_162_1   | 1                   | reality      | 2026-04-21 09:18:19 |
| 160 | 1       | 3e54f374-… | **f**     | (null)          | (null)              | (null)       | 2026-04-10 11:17:11 |

**Вывод:** один строковый `device_id` привязан к **двум пользователям**; активна запись **`user_id=23`** (REALITY). Попытка **`user_id=1`** активировать свою строку **`id=160`** с тем же `device_id` даёт **`UniqueViolation`** на частичном уникальном индексе по активному `device_id`.

---

## 2) Nginx: `$request_time` для `session/prepare`

**Формат access-лога** в репозитории и в контейнере (`server-config/nginx/nginx.conf`):

```nginx
log_format timed_combined '$remote_addr - $log_request_id [$time_local] '
                          '"$request" $status $body_bytes_sent '
                          'rt=$request_time urt=$upstream_response_time '
                          'uaddr=$upstream_addr';
```

- **`rt=`** — полное время запроса (клиент → nginx → upstream → ответ).
- **`urt=`** — время ответа upstream (часто ближе к «чистому» времени API).

**Практика:** полный `grep` по `/var/log/nginx/access.log` на проде может **занимать минуты** (очень большой файл). Добавлен скрипт, который читает только **хвост** внутри контейнера:

- `server-config/scripts/nginx_session_prepare_rt.sh`

Пример:

```bash
chmod +x server-config/scripts/nginx_session_prepare_rt.sh
./server-config/scripts/nginx_session_prepare_rt.sh granivpn_nginx 50000
```

Ручная выборка последних строк:

```bash
docker exec granivpn_nginx tail -n 15000 /var/log/nginx/access.log | grep 'session/prepare' | tail -20
```

---

## 3) Дашборд: 200 / 401 / 500 по `session_prepare` по дням

Источник: **`docker logs granivpn_api --since 168h`** (агрегация по дате в первом поле времени и `status=` в финальной строке `[session_prepare]`).

| День       | 200 | 401 | 500 |
|------------|-----|-----|-----|
| 2026-04-14 | 45  | 2   | 0   |
| 2026-04-15 | 22  | 1   | 0   |
| 2026-04-16 | 15  | 2   | 0   |
| 2026-04-17 | 5   | 1   | 0   |
| 2026-04-18 | 2   | 0   | 0   |
| 2026-04-19 | 1   | 0   | 0   |
| 2026-04-20 | 9   | 0   | 0   |
| 2026-04-21 | 9   | 1   | **11** |

Все **11×500** приходятся на **2026-04-21** и кластер **`device_id=3e54f374-…` / user_id=1**.

---

## 4) Лог причины отказа Google Play verify (без секретов)

**Сделано в коде:** `backend/api/payments.py`

- `_verify_google_play_purchase` теперь возвращает **`(data, fail_reason)`**.
- При ошибке Publisher API логируется **`Google Play Publisher API error (product_id=…): …`** с разбором **`googleapiclient.errors.HttpError`** (`http_status` + префикс тела ответа, **без** `purchase_token`).
- В **`[google-play-verify] publisher_no_data`** добавлено поле **`reason=%s`** (тот же безопасный текст).
- В **RTDN** ветках **RENEWED** / **RECOVERED** при неуспехе логируется **`reason=`**.

После деплоя по логам можно отличить: нет service account, **403/404** от Google, сетевой сбой и т.д.

---

## 5) Корреляция `xray_log_error` с 500 `session_prepare`

**Запрос к `telemetry_events`** (окно вокруг инцидента **2026-04-21 09:40–10:10 UTC**):

- События **`xray_log_error`** с **09:55** и **10:05** — пачки строк вида **`read tcp … i/o timeout`** (внутри `error_message` — **старый** timestamp лога ноды **2026/03/19**).
- **500 `session_prepare`** у **`user_id=1`** — **09:53–09:57** (по API-логам).

**Вывод:** всплеск **`xray_log_error`** в админке **не является причиной** 500 prepare: это **фоновый сбор** хвоста error-лога Xray с keyword `timeout`; по времени пачки **идут после** или **сдвинуты** относительно пика 500, а по смыслу 500 — **`IntegrityError` в PostgreSQL**, а не таймаут inbound Xray.

Дополнительно: почасовая агрегация **`xray_log_error`** за **2026-04-21 08–12 UTC** показывает стабильный фон (**40/час** в 08–09 и 09–10), т.е. **шум ноды**, слабо связанный с конкретным пользовательским prepare.

---

*При необходимости обновите дашборд после деплоя исправлений по `devices` и повторно снимите `docker logs` + хвост nginx.*

# Технический аудит: «туннель включён — интернета нет»

**Дата:** 2026-04-27  
**Окружение проверки:** хост с Docker (`granivpn_api`, `granivpn_postgres`), VPN-нода **HU-BUD-01** по SSH из API через `RemoteVPNManager` (ключ из БД, не логировался).

---

## 1. Резюме

| Слой | Статус | Вывод |
|------|--------|--------|
| API `/vpn/session/prepare` | Работает | В логах `status=200`, периодические `create_client_ms` до **~5.8 s** (SSH на ноду); не 4xx «уже подключено» в выборке |
| VPN-нода Xray | **active** | Порты **4443**, **8443**, **2053** слушает xray; **443** — nginx (ожидаемо) |
| Клиент (живой logcat) | Не снят | `adb`: только `emulator-5554 offline` — свежий logcat не собран |
| Исторические клиентские логи | Артефакт | В [granivpn_filtered.log](../granivpn_filtered.log) есть **`BSocksClient_Init failed`** / **`BConnector_Init failed`** (tun2socks path) — типичный класс «туннель/прокси сломан, трафик не идёт» |

**Интерпретация для симптома «VPN ON, нет сети»:** data-plane на ноде **жив**; типичные отказы в журнале — **VMess на 8443 с неверным UUID** (`invalid user > user do not exist`) и сканеры на REALITY. Для **легитимного** клиента следующий шаг — **сопоставить email клиента** (`userId_deviceId@granivpn.com`) в `access.log` во время сбоя: 0 accepted → клиент/конфиг/блок; есть accepted, но браузер пустой → DNS, NAT, IPv6-only ресурс, split tunnel.

---

## 2. Клиент (этап A — logcat)

### 2.1 Команда для повторного сбора на устройстве

Теги в коде:

- `GraniVpnService` — [VpnService.kt](../mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/VpnService.kt) (`TAG = "GraniVpnService"`), строка с **`[XRAY_EFFECTIVE_OUTBOUNDS]`** после обработки конфига.
- `XrayNativeWrapper` — [XrayNativeWrapper.kt](../mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/XrayNativeWrapper.kt).
- `XrayRoutingHelper` — [XrayRoutingHelper.kt](../mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/XrayRoutingHelper.kt) (режим DNS, REALITY strict port).

Пример фильтра:

```bash
adb logcat -v time GraniVpnService:D XrayNativeWrapper:D XrayRoutingHelper:D *:S
```

### 2.2 Артефакт из репозитория

В `granivpn_filtered.log` (2026-02-19) зафиксированы:

- маршрутизация к **45.12.132.94:8443** через **`[socks-in -> direct]`** (API proxy path);
- затем **`ERROR(BSocksClient): BConnector_Init failed`** и **`listener accept: BSocksClient_Init failed`**.

Это согласуется с правилом [.cursor/rules/vpn-diagnostics.mdc](../.cursor/rules/vpn-diagnostics.mdc): при поломке локального SOCKS/Xray цепочка не поднимается полностью — пользователь может видеть «VPN включён» при частичной инициализации (зависит от UI).

### 2.3 DNS / routing (код)

- Control-plane (`api.granilink.com`, IP API) уходит в **direct** при полной инъекции: [XrayRoutingHelper.applyFullVpnRouting](../mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/XrayRoutingHelper.kt).
- В режиме **`DNS_STRICT`** публичные DoH-домены **не** добавляются в direct — при проблемах резолвинга возможен сценарий «туннель есть, сайты не открываются».

---

## 3. VPN-нода (этап B–C)

Выполнено: `docker exec granivpn_api … python3 scripts/diagnostics_hu_bud_data_plane.py` (read-only).

- **systemd:** `xray` — **active (running)**.
- **Порты:** nginx **0.0.0.0:443**; xray **\*:4443, \*:8443, \*:2053**.
- **journalctl (свежие строки):** отказы на **8443** — преимущественно **`proxy/vmess/encoding: invalid user`** (чужой/устаревший UUID, не относится к VLESS-клиенту приложения без доп. проверки).
- **error.log (хвост на диске):** старые записи включают **`REALITY: failed to read client hello`**, **`server name mismatch`**, **`unsupported TLS version: 303`** — полезно сверять SNI/порт REALITY с выданным JSON.
- **access.log (хвост):** последние записи за **2026-03-19**; для текущего инцидента нужен **хвост за время воспроизведения** с grep по email клиента.

**Сверка inbound ↔ клиентский JSON:** автоматически не выполнялась (не выгружали полный `config.json` с ноды). Рекомендация: для пользователя с `email` из ответа `/vpn/connect` выполнить на ноде `grep 'email' /var/log/xray/access.log` за окно сбоя.

---

## 4. API и БД (этап D)

- **Логи `granivpn_api`:** `session_prepare` / `session_prepare_metric` с **200**; встречается **`create_client_ms=5851`** (долгий SSH-шаг на ноду) при всё ещё успешном ответе.
- **`GET /api/vpn/xray/apply-state`:** в логах встречаются **`middleware_total dt_ms≈15000`** — отдельный сигнал задержки (worth проверить блокировки/Redis/SSH в обработчике).
- **PostgreSQL `devices`:** несколько строк с **`is_active = true`** и **`vpn_protocol = vless`** для разных `device_id` — убедиться, что семантика `is_active` соответствует «одна активная VPN-сессия на пользователя» и не провоцирует рассинхрон UI/сервера (см. историю в [backend/VPN_DISCONNECT_FIX.md](../backend/VPN_DISCONNECT_FIX.md)).

В выборке логов за последние ~800 строк **нет** явных `paramiko` / `SSH` ошибок при connect.

---

## 5. Безопасность (этап F)

- **[.gitignore](../.gitignore):** `*.env`, `.env.production`, `env-production.env` и т.д. — **хорошо** для локальных секретов.
- **[TECHNICAL_AUDIT_REPORT.md](../TECHNICAL_AUDIT_REPORT.md):** по-прежнему актуален тезис о секретах в репозитории/примерах.
- **[server-config/docker/docker-compose.yml](../server-config/docker/docker-compose.yml):** в `environment` **зашиты** переменные вида `SMTP_PASSWORD`, `AWS_SECRET_ACCESS_KEY` (несколько сервисов, см. grep по именам переменных). Это **критичный риск** при коммите/шаринге репозитория: вынести в `env_file` / секреты хоста, **ротировать** ключи, если файл когда-либо утекал.

---

## 6. Рекомендации (приоритет)

1. **Снять logcat** на реальном устройстве при «нет интернета» (фильтр выше) + зафиксировать протокол (VLESS/REALITY) и строку **`[XRAY_EFFECTIVE_OUTBOUNDS]`**.
2. **На ноде** за то же окно: `tail`/`grep` по **email клиента** в `/var/log/xray/access.log` и релевантные строки в `error.log`.
3. Если в access.log **есть accepted**, проверить **NAT/sysctl/forwards** на ноде и **DNS strict** на клиенте.
4. Если в access.log **нет** записей — проверить **порт/security** (REALITY vs plain VLESS), **routing loop** (IP сервера в direct — уже в коде, но сверить фактический JSON).
5. **Убрать секреты из compose**, ротация ключей; не хранить значения в Git.

---

## 7. Критерий «где сломалось» (из плана)

- **0 строк** в Xray `access.log` по email клиента за окно сбоя → до ноды не доходит корректный протокол/пользователь или клиент не шлёт трафик в туннель.
- **Есть accepted**, но нет интернета в браузере → DNS, NAT, IPv6, split-tunnel, или отдельное приложение вне туннеля.

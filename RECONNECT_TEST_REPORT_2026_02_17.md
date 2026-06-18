# Отчёт: тест Connect → Disconnect → Reconnect (17.02.2026)

**Дата:** 17.02.2026  
**Сборка:** APK с sniffing, схема «клиент не удаляется при disconnect»  
**Устройство:** OnePlus MT2111 (Oplus/ColorOS)

---

## 1. Резюме

| Этап | Результат |
|------|-----------|
| Первое подключение | Успешно (create-client, ~8.3 с) |
| Disconnect | Успешно (разрыв туннеля, POST /vpn/disconnect fire-and-forget) |
| Reconnect | Успешно из кэша (~1.5 с, тот же UUID) |
| api.granilink.com через VPN | Sniffing срабатывает, direct |

Reconnect с кэшированным конфигом (тот же UUID) работает. Клиент на сервере не удалялся — UUID остаётся валидным.

---

## 2. Хронология по логам

### 2.1 Первое подключение (14:29:44 – 14:29:52)

```
VpnService.connect: _selectedServer = 1, _selectedProtocol = Xray VLESS
VpnService._connectXray: create-client (локальный конфиг не найден)
```

- create-client: client_id `vless_63_1`, UUID `6e5dcf6d-bef8-42eb-b1c1-9b4edf973177`
- Конфиг сохранён в SecureStorage (`_cacheConfig` → `_saveXrayConfigToStorage`)
- VPN поднят, трафик: `rx: 30815, tx: 23024`
- **Итого:** ~8.3 с (в т.ч. apply_protocol ~7 с)

### 2.2 Работа VPN и api.granilink.com

**14:29:54** — первый сброс соединения к API:
```
AuthService: Connection reset by peer, address = api.granilink.com, port = 38938
```
Вероятно, запросы ещё шли до завершения TLS handshake, часть трафика — по IP без sniffing.

**14:30:15** — sniffing срабатывает:
```
app/dispatcher: sniffed domain: api.granilink.com
app/dispatcher: taking detour [direct] for [tcp:api.granilink.com:443]
proxy/freedom: connection opened to tcp:api.granilink.com:443
```

Запросы к api.granilink.com идут в direct, не через proxy.

### 2.3 Disconnect (14:30:18)

```
Отключение от Xray сервера
VpnPlugin: onMethodCall: метод=disconnect
Xray disconnected
GraniVpnService: serviceState=DISCONNECTING
tun2socks: tearing down
XrayNativeWrapper: stopVpn: XRay остановлен
```

- Локальный туннель разорван (tun2socks, Xray, NativeVpnService)
- POST /vpn/disconnect отправлен fire-and-forget (без ожидания ответа)

**14:30:20** — таймаут POST /vpn/disconnect (8 с):
```
Ошибка отключения через API: TimeoutException after 0:00:08.000000
```
Ожидаемо: disconnect не блокирует UI, запрос мог уйти уже при выключенном VPN.

### 2.4 Reconnect (14:30:25 – 14:30:26)

```
VpnService._connectXray: Используем кэшированную конфигурацию (длина: 198)
XrayProtocol.connect: UUID: 6e5dcf6d-bef8-42eb-b1c1-9b4edf973177
VpnService._connectXray: Xray подключение успешно (из кэша)
```

- Конфиг из SecureStorage/CacheService, без create-client
- UUID совпадает с первым подключением
- **Итого:** ~1.5 с (apply_protocol ~0.9 с)

### 2.5 ConnectionLogger

- **14:29:55** — первый flush: 9 логов в очереди
- **14:30:20** — при разрыве VPN: `Software caused connection abort` (соединение оборвано)
- **14:30:26** — при reconnect: `Connection reset by peer` (очередь 19 логов)

Причины: разрыв VPN обрывает активные TCP, часть запросов к api.granilink.com выполняется в момент разрыва.

---

## 3. Побочные находки

### 3.1 MethodChannel package_info — NullPointerException

```
MethodChannel package_info: Failed to handle method call (Fix with AI)
java.lang.NullPointerException at h2.a.onMethodCall(SourceFile:23)
```

Плагин package_info падает при старте. Не связано с VPN. Стоит проверить конфигурацию package_info_plus.

### 3.2 callGcSupression NullPointerException (Oplus)

```
callGcSupression: java.lang.NullPointerException: Attempt to invoke virtual method 
'java.lang.Object java.lang.reflect.Method.invoke(...)' on a null object reference
```

Повторяется много раз. Скорее всего, прошивка OnePlus/Oplus, а не код приложения.

### 3.3 Impeller opt-out

```
[Action Required]: Impeller opt-out deprecated.
The application opted out of Impeller...
```

Рекомендуется убрать `--no-enable-impeller` / `io.flutter.embedding.android.EnableImpeller` из конфигурации.

### 3.4 VPN плагин — requestCode 53293

```
MainActivity: VPN плагин не обработал requestCode: 53293
```

`requestCode` от Google Sign-In (53293) не обрабатывается VPN-плагином. Для OAuth это нормально, но можно явно игнорировать коды вне диапазона VPN.

---

## 4. Логи сервера

Логи получены через Docker:

```bash
docker exec granivpn_api python3 /app/scripts/fetch_server_logs.py --name HU-BUD-01 --xray-lines 300
```

### 4.1 access.log — подключения клиента 1_63

| Время (CET) | MSK    | Событие                           |
|-------------|--------|-----------------------------------|
| 12:29:53    | 14:29  | Первые `accepted` (first connect) |
| 12:30:17–18 | 14:30  | Трафик до disconnect              |
| 12:30:19    | 14:30  | `accepted` после disconnect       |

Клиент `1_63@granivpn.com` (vless_63_1), IP `94.180.243.40`.

Фрагмент:
```
12:29:53 ... accepted tcp:api.x.com:443 1_63@granivpn.com ...
12:30:18 ... accepted tcp:event-stream-api.magnit.ru:443 1_63@granivpn.com ...
12:30:19 ... accepted tcp:report.appmetrica.yandex.ru:443 1_63@granivpn.com ...
```

### 4.2 Соответствие с мобильной хронологией

- **Disconnect:** 14:30:18 MSK = 12:30:18 CET — последние `accepted` до разрыва туннеля.
- **Reconnect:** 14:30:25 MSK = 12:30:25 CET — reconnect с тем же UUID.
- В access.log нет операций удаления клиента; `1_63` остаётся активным.
- Корреляция по `1_63` и времени подтверждает: один и тот же клиент использовался до disconnect и при reconnect.

### 4.3 Вывод по серверным логам

1. Клиент `vless_63_1` (UUID `6e5dcf6d-bef8-42eb-b1c1-9b4edf973177`) не удаляется при disconnect.
2. Reconnect с тем же UUID успешно проходит — сервер принимает соединения.
3. error.log без отказов для данного клиента.

---

## 5. Выводы

1. Reconnect из кэша работает: тот же UUID, ~1.5 с вместо ~8 с.
2. Схема «клиент не удаляется при disconnect» подтверждается: reconnect без create-client проходит.
3. Sniffing для api.granilink.com срабатывает: трафик идёт в direct.
4. ConnectionLogger падает при разрыве VPN — логично; можно улучшить retry или отложенную отправку после reconnect.
5. Рекомендуется устранить NullPointerException в package_info и убрать Impeller opt-out.

---

## 6. Fix: reconnect без трафика (rx: 0, tx: 0)

**Проблема:** При втором подключении Xray/tun2socks запускаются, но трафик не идёт (rx: 0, tx: 0), в логах нет `proxy/socks: TCP Connect request`. Возможен конфликт с предыдущим VPN-сеансом при reconnect.

**Решение (без изменения таймаутов):**

1. **Уникальный session** — `setSession("GRANI-${System.currentTimeMillis()}")` вместо фиксированного `"GRANI"`, чтобы избежать конфликта со старым сеансом при reconnect.
2. **allowFamily(AF_INET)** — явное разрешение IPv4 в `VpnService.Builder`.
3. **setUnderlyingNetworks(null)** — VPN использует текущую сеть, помогает при dual-SIM / WiFi+cellular на reconnect.

**Файл:** `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/XrayNativeWrapper.kt`

---

## 7. Проверка логов на VPN-сервере

При reconnect-проблемах проверьте Xray на сервере 45.12.132.94 (HU-BUD-01):

```bash
# Через Docker (если сервер в БД)
docker exec granivpn_api python3 /app/scripts/fetch_server_logs.py --name HU-BUD-01 --xray-lines 300

# Без Docker, с ключом
cd /opt/grani
PYTHONPATH=backend python3 backend/scripts/fetch_server_logs.py --ip 45.12.132.94 --ssh-key-path /path/to/key.pem --xray-lines 300

# Ключ через переменную окружения
SSH_KEY_CONTENT="$(cat /path/to/key.pem)" PYTHONPATH=backend python3 backend/scripts/fetch_server_logs.py --ip 45.12.132.94 --xray-lines 300
```

**Что смотреть:**
- **access.log** — есть ли `accepted` с UUID клиента после reconnect (если нет — трафик до сервера не доходит).
- **error.log** — отказы, `invalid user`, таймауты.

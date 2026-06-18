# Сценарии: подключение, реконнект, отключение VPN

Только та часть сервиса, которая отвечает за **подключение**, **реконнект** и **отключение** VPN (без подписок, оплат, авторизации и т.п.).

---

## 1. Подключение (первое или повторное из приложения)

**Точка входа:** пользователь нажимает «Подключиться» в приложении → `ConnectVpnUseCase.connect()` → `VpnService.connect()`.

**Шаги:**

1. **Проверки до API:** разрешение VPN, выбранный сервер, подписка/триал (не вызываем API без доступа).
2. **Триггер:** `_connectionTrigger = 'first_connect'` (или `'reconnect_after_network_change'` при реконнекте после смены сети).
3. **Опционально: синхронизация состояния с сервером** — при первом connect в сессии вызывается `_syncConnectionState()`: запрос статуса устройства к API; при расхождении (на сервере «подключено», в приложении — нет) выполняется принудительное отключение на сервере (POST /vpn/disconnect), затем подключение продолжается.
4. **Пауза после недавнего disconnect:** если с момента последнего отключения прошло меньше 500 ms, выдерживается пауза до 500 ms (избегаем гонки tun2socks при быстром повторном подключении).
5. **Конфиг Xray:**
   - **Вариант A — из кэша (reconnect без API):** тот же сервер и протокол, в Secure Storage есть валидный конфиг (порт и поля совпадают с ожидаемыми) → `XrayConnectionHandler.getCachedConfig()` → конфиг не запрашивается с API, сразу `applyConfig()`.
   - **Вариант B — с API:** кэша нет или он невалиден → **POST /api/vpn/xray/create-client** (server_id, protocol, device_id) → ответ: json_config, client_id, ip_address → конфиг сохраняется в кэш → `applyConfig()`.
   - **Подвариант при 400 «уже подключено»:** если create-client вернул 400 с текстом «уже подключено» / «already connected», приложение вызывает принудительное отключение на сервере (`_forceDisconnectOnServer` → **POST /api/vpn/disconnect** с телом `device_id`), ждёт 500–1000 ms, затем повторяет запрос create-client.
6. **Применение к нативному слою:** `XrayConnectionHandler.applyConfig()` → Flutter формирует JSON конфиг для Xray → вызов платформенного канала `startVpnConnection(config, protocol, mtu)` → **VpnPlugin** → `GraniVpnService.startService(context, config, protocol, mtu)`.
7. **Android VpnService:** `onStartCommand(ACTION_START)` → `startVpn(config, …)` → выбор адаптера (Xray) → **in-process:** `processXrayPacketsInProcess()` → при быстром переподключении после stop выдерживается задержка перед `establish()` (reconnect delay из SharedPreferences) → `XrayNativeWrapperTun2Socks` → создание TUN (`VpnService.Builder().establish()`), запуск tun2socks, запуск libXray с переданным конфигом.
8. **Бэкенд (при варианте B):** create-client обновляет конфиг на VPN-ноде (кэш + фоновая задача Celery `vpn.apply_xray_config` или синхронный apply по SSH). При быстром пути (клиент уже в кэше конфига на API) ответ без SSH/Celery. Клиент на сервере не удаляется при отключении — следующий reconnect может быть из кэша.
9. **После поднятия туннеля:** проверка трафика (verifyConnection), логирование `connection_success` / `traffic_first_seen`, переход в состояние connected, старт мониторинга трафика и слушателя смены сети.

**Состояния (VpnConnectionState):** idle → connecting → connected (или error).

---

## 2. Реконнект после смены сети

**Точка входа:** приложение подключено, `ConnectivityPlus` фиксирует смену сети (Wi‑Fi ↔ мобильные данные и т.д.) → в `VpnService` вызывается колбэк смены сети.

**Условия:** не в «grace period» после resume приложения, прошёл минимальный интервал с последнего реконнекта (`reconnectMinIntervalAfterNetworkChange`).

**Шаги:**

1. **Флаг:** `_reconnectAfterNetworkChange = true`.
2. **Отключение:** вызывается `disconnect()` (см. раздел 6). При этом **не ждём** ответа API отключения — сразу переходим к локальному отключению и по завершении планируем `connect()` с задержкой `reconnectAfterNetworkChangeDelay` (200 ms).
3. **Повторное подключение:** по таймеру вызывается `connect()`. `_connectionTrigger = 'reconnect_after_network_change'`. Дальше логика как в разделе 1 (в т.ч. пауза после disconnect при необходимости): конфиг из кэша или create-client, затем apply к нативному слою.
4. **Нативный слой:** при каждом новом подключении выполняется **полный старт** (новый TUN, новый процесс tun2socks при отдельном процессе), без `attachTun`. Перед `establish()` при быстром переподключении после stop выдерживается задержка `reconnectDelayMs` (из SharedPreferences `grani_vpn_reconnect`).

**Логирование:** stage `reconnect_start`, trigger `reconnect_after_network_change`; при использовании кэша — stage `reconnect_from_cache`, trigger `reconnect_from_cache`.

---

## 3. Реконнект из кэша (тот же сервер/протокол)

**Точка входа:** пользователь снова нажимает «Подключиться» после отключения (или реконнект после смены сети), сервер и протокол не менялись.

**Условие:** в Secure Storage есть конфиг для пары (server_id, protocol), он валиден (порт и обязательные поля совпадают с ожидаемыми для протокола).

**Шаги:**

1. В `_connectXray()` вызывается `handler.getCachedConfig(server, protocol)`. Если результат не null и конфиг валиден — API не вызывается.
2. Логирование: stage `reconnect_from_cache`, trigger `reconnect_from_cache`.
3. `handler.applyConfig(cached.jsonConfig, …)` → тот же путь, что и в разделе 1 (платформенный канал → VpnService → TUN + tun2socks + Xray).
4. Кэш при обычном disconnect **не очищается** — специально для быстрого повторного подключения без create-client.

**Примечание:** при ошибке применения конфига из кэша кэш сбрасывается и выполняется запрос create-client (свежий конфиг с API).

---

## 4. Реконнект с панели быстрых настроек (Quick Tile)

**Точка входа:** пользователь тапает по плитке VPN в шторке (Quick Tile) → открывается `QuickTileToggleActivity` (или сразу старт, если разрешение уже дано).

**Шаги:**

1. **Конфиг:** берётся последний сохранённый на стороне Android: `VpnPlugin.loadLastConfig(context)`. Этот конфиг (и протокол) **сохраняется в VpnPlugin после того, как VpnService подтвердил запуск** (`GraniVpnService.isVpnRunning() == true`), т.е. после успешного старта VPN из приложения. API и Flutter-кэш при нажатии на плитку не вызываются.
2. Если конфига нет — показывается «Нет конфигурации», плитка обновляется.
3. Сбрасывается флаг «VPN остановлен пользователем» в `grani_vpn_reconnect` и вызывается `GraniVpnService.startService(context, lastConfig.config, lastConfig.protocol)`.
4. Дальше как в разделе 1: VpnService получает конфиг в `onStartCommand(ACTION_START)` и поднимает TUN + tun2socks + Xray. Flutter-слой не участвует до следующего открытия приложения (состояние connected приложение узнает при открытии через статус сервиса/канал).

**Ограничение:** используется только последний сохранённый конфиг; смена сервера/протокола возможна только из приложения.

---

## 5. Авто-реконнект при обрыве (периодические попытки)

**Точка входа:** включён «Авто-реконнект»; VPN перешёл в состояние disconnected/error (например, обрыв связи или падение процесса).

**Шаги:**

1. В `VpnService` запускается таймер `_reconnectionTimer` (период 10 с). При срабатывании проверяется: не connected, авто-реконнект включён, число попыток меньше лимита.
2. Увеличивается счётчик попыток, пауза `_reconnectionDelay` (5 с), затем вызывается `connect()`.
3. При успешном подключении таймер останавливается, счётчик сбрасывается. Логика конфига та же: кэш или create-client, затем apply.

---

## 6. Отключение (пользователь нажимает «Отключиться»)

**Точка входа:** пользователь нажимает «Отключиться» в приложении → `VpnService.disconnect()`.

**Шаги:**

1. Если идёт connect — ожидание до N попыток по 100 ms (`disconnectWaitConnectMaxAttempts`), затем отключение всё равно выполняется.
2. Переход в состояние disconnecting, остановка мониторинга трафика и слушателя смены сети.
3. **API отключения:** при наличии токена и device_id отправляется **POST /api/vpn/disconnect** с телом **`device_id`** (строка). Вызов выполняется **всегда** (не опционально); ожидание ответа ограничено таймаутом (`disconnectUiWaitMax` 2 с), по истечении — fire-and-forget, отключение локально не блокируется.
4. **Локальное отключение Xray:** `_disconnectXray()` → `stopXray()` → `stopXrayFull()`: остановка Xray (native/libXray), закрытие TUN (и при in-process — остановка tun2socks, затем закрытие дескриптора). Клиент на VPN-сервере **не удаляется** — reconnect из кэша остаётся возможным.
5. Логирование `connection_end` (duration, bytes sent/received, trigger).
6. Переход в disconnected. Кэш конфига **не очищается** (для reconnect из кэша). Если был запланирован реконнект после смены сети — по таймеру вызывается `connect()`.

**Состояния:** connected/disconnecting → disconnected (или idle/error при сбое).

---

## 7. Отключение при смене сети (в рамках реконнекта)

Отключение вызывается из колбэка смены сети с флагом `_reconnectAfterNetworkChange = true`. Последовательность та же, что в разделе 6, но вызов **POST /api/vpn/disconnect** не ожидается (fire-and-forget с самого начала). После перехода в disconnected по истечении `reconnectAfterNetworkChangeDelay` вызывается `connect()` (раздел 2).

---

## 8. Цепочка на стороне бэкенда (только связка с VPN)

- **POST /api/vpn/xray/create-client:** создаёт/возвращает клиента Xray для (server_id, protocol, device_id). Возвращает json_config, client_id; на сервере конфиг применяется в фоне (Celery) или синхронно. При быстром пути (клиент уже в кэше конфига на API) ответ без SSH/Celery.
- **GET /api/vpn/xray/config/{client_id}:** по client_id можно получить конфиг; в текущих сценариях приложения в основном используют create-client и кэш, не GET config.
- **POST /api/vpn/disconnect:** тело запроса — **device_id** (строка) **или** **client_id** (строка); в сценариях из приложения всегда передаётся **device_id**. Сбрасывает состояние устройства в БД; **Xray-клиент на VPN-ноде не удаляется** (для быстрого реконнекта из кэша).

---

## Краткая схема

| Сценарий                    | Конфиг откуда            | API вызовы                         | Нативный слой        |
|----------------------------|--------------------------|------------------------------------|----------------------|
| Первое подключение         | API (create-client)      | create-client (при 400 «уже подключено» — disconnect, затем повтор create-client) | Полный start (TUN+Xray) |
| Reconnect из приложения    | Кэш или API              | Нет или create-client              | Полный start         |
| Reconnect после смены сети | Кэш или API              | disconnect (fire-and-forget), затем при connect — нет или create-client | disconnect → полный start |
| Quick Tile                 | Last config (Android), сохраняется после подтверждения VpnService, что VPN запущен | Нет | Полный start         |
| Отключение                 | —                        | disconnect с телом device_id (ожидание ответа до disconnectUiWaitMax, затем fire-and-forget) | stopXrayFull, TUN close |
| Отключение при смене сети  | —                        | disconnect (fire-and-forget)       | то же + затем connect() по таймеру |

Все сценарии подключения в нативном слое выполняются как **полный старт** (новый TUN, при необходимости новый процесс tun2socks, запуск Xray). Режим «attachTun» (переиспользование уже запущенного Xray) в текущей реализации не используется.

---

## Реализованные исправления и тесты (по критическому анализу)

- **Backend:** в `create_xray_client()` добавлена проверка `device.is_active`; при уже подключённом устройстве возвращается 400 «Устройство уже подключено» (клиент выполняет force disconnect + retry). В `disconnect_device()` клиент на ноде не удаляется (тест `test_disconnect_device_does_not_remove_client_on_node`).
- **Flutter:** при 400 от create-client обрабатывается поле `detail` (FastAPI); включена синхронизация состояния при первом connect в сессии (`_skipSyncConnectionStateOnConnect = false`); при resume вызывается `syncConnectionStateWithServer()` для согласования с сервером (в т.ч. после отключения через Quick Tile).
- **Тесты backend:** `test_vpn_connect_api.py` — POST /api/vpn/xray/create-client (200, json_config, client_id), POST /api/vpn/disconnect с телом device_id (200, сброс is_active). Для прогона API-тестов нужен httpx<0.28: `pip install -r requirements.txt -r requirements-test.txt`.
- **Тесты Flutter:** `xray_connection_handler_test.dart` — reconnect из кэша без вызова create-client, 400 → force disconnect → повтор create-client; e2e — проверка, что disconnect отправляет device_id в теле.
- **CI:** `.github/workflows/backend-tests.yml` — установка requirements-test.txt и запуск pytest при изменениях в backend.

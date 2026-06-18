# Выводы по логам: Xray, краш при отключении, мобильный трафик, перерегистрация

## 1. Краш при отключении VPN (исправлено)

**Симптом:** `FORTIFY: pthread_mutex_lock called on a destroyed mutex`, `SIGABRT` в потоке processXrayPackets / tun2socks.

**Причина:** При остановке сначала вызывался `stopTun2Socks()`, поток tun2socks завершался и уничтожал мьютекс, после чего вызывался `delegate?.stopVpn()` (остановка Xray). Другой поток (или сам Xray/Go) ещё обращался к общему состоянию → use-after-free по мьютексу.

**Исправление:** В `XrayNativeWrapperTun2Socks.stopVpn()` изменён порядок:
1. Сначала останавливаем Xray (`delegate?.stopVpn()`), чтобы трафик в SOCKS прекратился.
2. Пауза 400 ms для освобождения соединений.
3. Затем `tun2socksRunning.set(false)`, `stopTun2Socks()`, `thread.join()`.

Дополнительно (повторный краш): `stopVpn()` сделан идемпотентным — флаг `stopped` не даёт выполнять остановку дважды (главный поток при ACTION_STOP и поток `processXrayPackets` в `finally`). В `VpnService` исправлена дублирующая строка `val mtu = ...` и MTU из intent передаётся в `startVpn()`; в wrapper добавлен параметр `mtu` и поле `tunMtu` для tun2socks.

Файл: `android/app/src/main/kotlin/com/granivpn/mobile/XrayNativeWrapperTun2Socks.kt`, `VpnService.kt`.

---

## 2. Перерегистрация после перезапуска (улучшено)

**Симптом:** После перезапуска приложения (в т.ч. после краша) пользователю снова предлагают регистрацию или логи с устройства не принимаются (404 по device_id).

**Причина:** device_id должен загружаться из хранилища до любых API-запросов; при холодном старте в цикле с токеном мы вызывали `ensureDeviceRegistered(token)` до явной проверки, что `_deviceId` уже загружен.

**Исправление:** В `_initialize()` в цикле после получения токена добавлена явная загрузка: `if (_deviceId == null) await _loadDeviceId();` перед установкой credentials и вызовом `ensureDeviceRegistered(token)`. Так после перезапуска device_id гарантированно восстанавливается из storage до отправки логов и регистрации.

Файл: `lib/services/vpn_service.dart`.

---

## 3. Скорость 0 на мобильном трафике (улучшено)

**Симптом:** На мобильной сети (cellular) скорость через VPN нулевая; на Wi‑Fi или в Amnezia VPN на мобильной сети всё работает.

**Причина:** Слишком большой MTU для сотовых сетей (фрагментация/потеря пакетов). В коде использовался MTU 1420 для всех типов сети.

**Исправления:**
- В Dart для mobile уже заданы `_mtuMobile = 1280`, `_mtuDefault = 1400`.
- Добавлена передача MTU с Flutter на нативный слой: `NativeVpnService.connect(..., mtu: selectedMtu)`, в Android intent `EXTRA_MTU`, в `GraniVpnService` → `requestedMtu` → `processXrayPackets` → `XrayNativeWrapperTun2Socks.startVpn(..., mtu)` и `XrayNativeWrapper.startVpn(..., mtu)`. TUN создаётся с `setMtu(tunMtu)` (1280–1500), tun2socks тоже получает этот MTU.

Файлы: `lib/services/native_vpn_service.dart`, `lib/services/vpn_service.dart` (mtu в connect), `VpnPlugin.kt`, `VpnService.kt` (GraniVpnService), `XrayNativeWrapperTun2Socks.kt`, `XrayNativeWrapper.kt`.

---

## 4. Xray протокол — что видно по логам

По логам мобильного приложения и сервера:

- **Подключение устанавливается:** API возвращает `success: true`, client_id (vless_45_1 / reality_36_1), конфиг приходит, Xray на клиенте поднимает SOCKS, идут `tunneling request to tcp:... via 45.12.132.94:4443`.
- **Случай «подключено, но нет интернета»** (Reality/VLESS): типично проблема на стороне сервера — маршрутизация, NAT (MASQUERADE), `net.ipv4.ip_forward`, либо исходящий доступ с сервера. По клиентским логам туннель и DNS (1.1.1.1:53, 9.9.9.9:53) через proxy работают.
- **Проверки на клиенте:** «Не удалось получить текущий IP» и «Слишком много запросов» при проверке DNS — чаще из-за таймаута проверки IP или rate limit на API проверки, а не из-за поломки Xray.

**Рекомендации по серверу (Xray/Reality):** проверить логи Xray на сервере (`scripts/fetch_server_logs.py --name HU-BUD-01`), iptables/NAT для исходящего трафика, `ip_forward`, доступность интернета с самого сервера.

---

## 5. Подключился по Wi‑Fi, выключил Wi‑Fi (остался на мобильном) — работало, потом скорость падала и связь пропала

**Симптом:** VPN поднят по Wi‑Fi, всё ок. Отключили Wi‑Fi, остались на мобильном трафике — сначала работало, затем скорость упала и соединение «умерло». После включения Wi‑Fi снова всё в порядке.

**С чем это связано:**

1. **Смена сети без переподключения VPN**  
   Туннель был установлен с IP, выданным по Wi‑Fi. После перехода на мобильный трафик у телефона другой исходящий IP (и часто CGNAT у оператора). Сервер продолжает слать пакеты на старый IP (Wi‑Fi) → они не доходят. Со стороны клиента ответы идут уже с нового IP → сервер может их отбрасывать или не ассоциировать со старым соединением. В итоге туннель «ломается»: задержки, обрывы, нулевая скорость.

2. **MTU при смене сети**  
   При подключении по Wi‑Fi используется MTU для Wi‑Fi (например 1400). После перехода на мобильный трафик путь меняется (другой оператор, другие маршруты), но активное VPN-соединение продолжает использовать старый MTU. На мобильных сетях часто нужен меньший MTU (у нас 1280 для cellular). Пакеты могут фрагментироваться/теряться → падение скорости и обрывы.

3. **Таймауты и NAT у оператора**  
   У сотовых операторов агрессивный NAT и таймауты неактивных соединений. Долгоживущий TCP/UDP-туннель, поднятый по Wi‑Fi, после переключения на мобильный может оказаться «полуживым»: оператор рвёт неактивные сессии, пакеты не доходят — связь пропадает.

**Что смотреть в логах:**

- **client_logs:** события `connection_start` / `connection_stage` / `connection_end` и при наличии `connection_error`. В `error_details` (JSON) может быть поле `network_type` (wifi / mobile). Полезно смотреть пары: начало сессии с каким `network_type`, конец — с каким, и `connection_duration_ms`.
- **connection_logs:** время `connected_at` / `disconnected_at`, `duration_seconds` — как долго сессия «висела» до обрыва.

Проверка логов по пользователю (админка): «Логи по пользователю» → ввести user id или найти по email → загрузить диагностику. Либо скрипт:  
`backend/scripts/check_client_logs_status.py <email>` — покажет последние client_logs. В БД в `client_logs.error_details` хранится JSON с `network_type` и `stage`.

**Реализовано в приложении:**

- При смене типа сети (Wi‑Fi ↔ mobile/ethernet) во время подключённого VPN приложение **автоматически** отключается и через ~0,8 с переподключается с актуальным MTU и маршрутами. Используется `connectivity_plus.onConnectivityChanged`, debounce 2 с (чтобы не реагировать на кратковременные «none»). См. `VpnService._startNetworkChangeListener`, `_stopNetworkChangeListener`, флаг `_reconnectAfterNetworkChange`.

---

## Итог по трём задачам

| Проблема | Статус | Где правки |
|----------|--------|------------|
| Краш при отключении VPN | Исправлено | XrayNativeWrapperTun2Socks.kt (порядок остановки Xray → tun2socks) |
| Перерегистрация после перезапуска | Улучшено | vpn_service.dart (_initialize: загрузка device_id до ensureDeviceRegistered) |
| Скорость 0 на мобильном трафике | Улучшено | MTU 1280 для mobile, передача MTU Flutter → Android, использование в TUN и tun2socks |

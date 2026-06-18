# Анализ: Connect / Disconnect / Reconnect — протоколы, кнопка, бекенд, мобильное приложение

См. также: [Boring HTTPS — развёртывание и диагностика](BORING_HTTPS_DEPLOY.md).

**Цель:** Упростить цепочку подключения/отключения для стабильной работы VPN. Не трогаем авторизацию и бизнес-логику.

---

## 1. Текущая цепочка при Connect

```
Кнопка → VpnService.connect()
  → _connectStagePermissions
  → _connectStageDeviceAndNetwork  (device_id, MTU)
  → _connectStageTokenAndSync      (токен, _syncConnectionState)
  → _connectStageSelectServerAndLogStart
  → _connectStageGetConfig         (кэш или API)
  → _connectStageApplyProtocol
  → _connectStageVerify
  → _connectStageOnSuccess
```

### Различия по протоколам

| Протокол | API конфига | Этап get_config | Этап apply |
|----------|-------------|-----------------|------------|
| Xray (VLESS/VMess/Reality) | create-client или кэш | Конфиг не берётся (null) | _connectInternal → _connectXray → create-client / кэш → _applyXrayConfig → NativeVpnService.connect |
| WireGuard / GraniWG | /vpn/connect | POST /vpn/connect | _applyWireGuardConfig → NativeVpnService.connect |
| Boring HTTPS | /vpn/connect | — | _connectBoringHttps |
| OpenVPN Cloak | /vpn/connect | POST /vpn/connect | _applyOpenVPNCloakConfig |

### Регистрации и sync при Connect

- **device_id:** Загружается в `_loadDeviceId` (из хранилища или resolve/register). Без device_id бекенд использует «один коннект на user+server+protocol».
- **_syncConnectionState:** Выполняется **раз в сессию** (`_connectionStateSyncDoneThisSession`). GET /vpn/status → если сервер считает устройство подключённым, а локально нет → _forceDisconnectOnServer.
- **ensureDeviceRegistered:** Вызывается при инициализации (холодный старт) и после логина. POST /vpn/device/register. **При успехе вызывает `_clearConfigCache()`** — это может очищать Xray SecureStorage, если `_selectedServer` уже выбран.

---

## 2. Текущая цепочка при Disconnect

```
Кнопка → VpnService.disconnect()
  → POST /vpn/disconnect (fire-and-forget, timeout 8 с)
  → _disconnectWireGuard / _disconnectXray / … (локальный разрыв)
  → _connectionStateSyncDoneThisSession = false
  → _clientId = null
  → _clearConfigCache() — отключено (_diagnosticAllowReconnectFromCache = true)
  → _lastDisconnectCompletedAt = now
```

### Android Native

- **GraniVpnService.stopVpn()** → adapter.stop() → XrayAdapter → stopXrayFull() → xrayNativeWrapper.stopVpn() → XrayNativeWrapperTun2Socks.stopVpn()
- **stopVpn:** Tun2Socks.resetForRestart, stopTun2Socks, join потока tun2socks, delegate.stopVpn(). Сервис вызывает stopSelf().

---

## 3. Второй Connect (Reconnect)

### Xray

- Если в SecureStorage есть конфиг → `_getXrayConfigFromStorage()` → `_applyXrayConfigFromCache` → `_applyXrayConfig` → NativeVpnService.connect.
- Без кэша → create-client → `_parseAndApplyXrayResponse` → `_applyXrayConfig`.

### Нативный слой (второй connect)

- GraniVpnService уничтожен при disconnect (stopSelf). Новый connect = новый startForegroundService → новый экземпляр сервиса.
- XrayAdapter каждый раз создаёт **новый** XrayNativeWrapperTun2Socks, новый delegate (XrayNativeWrapper). Полный цикл: TUN → libXray → tun2socks.

### Проблема «второй connect без трафика»

- По логам: tun2socks запущен, но в него не попадает трафик (нет `proxy/socks: TCP Connect request`).
- Возможные причины:
  1. TUN при втором `Builder.establish()` не получает маршруты/трафик.
  2. Гонка: tun2socks стартует до того, как libXray поднял SOCKS.
  3. Состояние libXray после stopVpn не полностью сброшено.

---

## 4. WireGuard и GraniWG — почему могут не работать

- WireGuard и GraniWG используют один и тот же нативный WireGuardAdapter (AmneziaWG/GoBackend).
- Оба идут через POST /vpn/connect с `protocol: wireguard` или `protocol: graniwg`.
- Бекенд должен возвращать конфиг в формате [Interface]/[Peer]. Для GraniWG — возможны доп. параметры (Jc, S1, …), которые `stripAmneziaWgParams` убирает.
- Возможные проблемы:
  1. Бекенд не отдаёт корректный конфиг для wireguard/graniwg.
  2. Формат конфига не совместим с AmneziaWG.
  3. Сервер не в списке supportedProtocols для wireguard/graniwg.

---

## 5. Что можно упростить / отключить (для стабильного connect/disconnect)

### 5.1 Можно отключить/упростить (без влияния на авторизацию)

| Элемент | Действие | Обоснование |
|---------|----------|-------------|
| **_syncConnectionState при connect** | Временно отключить (не вызывать в _connectStageTokenAndSync) | Уменьшает задержки и возможные race при первом connect. Sync можно вернуть после стабилизации. |
| **Очистка кэша в _registerDeviceIfNeeded** | Убрать вызов `_clearConfigCache()` при успешной регистрации | Регистрация устройства не должна стирать кэш VPN-конфига — это мешает быстрому reconnect. |
| **ConnectionLogger.flush при disconnect** | Не блокировать disconnect ожиданием flush | Логирование не должно задерживать разрыв туннеля. |
| **Пауза 2 с после disconnect** (_minDelayAfterDisconnect) | Оставить, но не увеличивать | Уже есть для tun2socks; не добавлять дополнительные паузы. |
| **Верификация при reconnect из кэша** | Ослабить: если конфиг из кэша и трафик появился в течение 3 с — считать success | Ускорить переход в «Подключено» при reconnect. |

### 5.2 Не трогать

- Авторизацию (токен, refresh).
- `_loadDeviceId`, resolve, register — нужны для бекенда.
- POST /vpn/disconnect — важен для синхронизации состояния на сервере.
- create-client для Xray — нужен при первом connect.

### 5.3 Исправления для второго Connect (Xray)

1. **Гарантировать порядок:** libXray поднимает SOCKS → затем tun2socks. DELAY_BEFORE_TUN2SOCKS_MS уже 700ms — при необходимости проверить, достаточно ли этого после полного stop.
2. **Сброс libXray:** Убедиться, что при stopVpn libXray полностью освобождает порты и ресурсы перед следующим start.
3. **TUN на втором establish:** Проверить, что `Builder.establish()` при повторном запуске сервиса возвращает валидный fd и маршрутизация применяется корректно.

### 5.4 WireGuard / GraniWG

1. Проверить ответ бекенда на POST /vpn/connect для protocol=wireguard и protocol=graniwg.
2. Убедиться, что сервер имеет wireguard_public_key, wireguard_port и supportedProtocols содержит `wireguard` / `graniwg`.
3. Логировать сырой конфиг перед передачей в WireGuardAdapter для отладки.

---

## 6. Краткий чеклист изменений для упрощения

- [x] Отключить вызов `_syncConnectionState` при connect (временно) — `_skipSyncConnectionStateOnConnect = true`.
- [x] Убрать `_clearConfigCache()` из `_registerDeviceIfNeeded`.
- [x] ConnectionLogger не блокирует disconnect (logConnectionEnd добавляет в очередь, без await).
- [ ] (Опционально) Ослабить _verifyConnection при reconnect из кэша.
- [ ] Проверить порядок инициализации libXray → tun2socks на втором connect.
- [ ] Добавить логирование конфига WireGuard/GraniWG перед передачей в нативный слой.

---

## 7. Сводка: что может «ломать» подключение

| Фактор | Влияние |
|--------|---------|
| _syncConnectionState | Disconnect на сервере при «несовпадении» состояния — может убить активный сеанс. |
| _clearConfigCache при register | Стирает Xray-кэш, вынуждает повторный create-client. |
| Порядок libXray ↔ tun2socks | При гонке tun2socks подключается к неготовому SOCKS. |
| TUN при повторном establish | Возможны проблемы с маршрутизацией/состоянием на Android. |
| Неверный конфиг WireGuard/GraniWG | Бекенд или формат конфига — нативный слой не может поднять туннель. |

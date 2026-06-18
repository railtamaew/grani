# Анализ проблемы reconnect в нативном слое

## Симптомы

- **Первый connect**: VPN работает, tun2socks показывает `proxy/socks`, трафик идёт.
- **Reconnect** (повторное подключение VLESS или смена на Reality/VMESS): приложение показывает connected, но **трафик не идёт** — TUN не получает пакеты (нет строк `proxy/socks` в логах tun2socks).

## Диагностика (без использования "больше времени")

### 1. Жизненный цикл TUN

**Порядок при disconnect:**
1. `XrayNativeWrapperTun2Socks.stopVpn()` → `Tun2Socks.stopTun2Socks()` → native tun2socks завершается
2. `thread.join(3500)` — ожидание завершения Java-потока tun2socks (который закрывает `pfdDup` в `finally`)
3. `delegate?.stopVpn()` → `XrayNativeWrapper.cleanup()` → закрытие `vpnInterface` (основного TUN fd)

Порядок корректен: tun2socks выходит до закрытия TUN.

### 2. Поток выполнения establish()

`VpnService.Builder.establish()` вызывается в **фоновом потоке**:
- `XrayAdapter.start()` → `Thread { processXrayPackets(config) }.start()`
- `processXrayPacketsInProcess()` → `xrayNativeWrapper?.startVpn()` → `XrayNativeWrapper.startVpn()` → `builder.establish()`

ConnectivityService/VpnService в Android могут иметь неявные ожидания о потоке вызова. При reconnect это может приводить к некорректному обновлению маршрутов.

### 3. Разделение владения PFD

- В in-process режиме: `GraniVpnService.vpnInterface` **никогда не устанавливается**, PFD хранится только в `XrayNativeWrapper.vpnInterface`
- При `stopXrayFull()` вызывается `vpnInterface?.close()` у `GraniVpnService` — это всегда null, реальное закрытие происходит в `XrayNativeWrapper.cleanup()`
- Функционально это ок, но источник владения TUN размыт

### 4. Android VPN и reconnect

Из документации: *"The application must drain the old descriptor and close it before using the new one."*
- Drain выполняется через остановку tun2socks (читателя) перед закрытием TUN
- Синхронное ожидание полной разборки VPN в ConnectivityService не гарантируется — возможен timing-sensitive баг на некоторых устройствах

### 5. Путь reconnect в in-process

- `stopXrayFull()` устанавливает `xrayNativeWrapper = null`
- При следующем connect `wrapper == null` → всегда идём по пути **полного start** (новый `XrayNativeWrapperTun2Socks`)
- `attachTun` в in-process при full stop **не используется** — это ожидаемо

## Рекомендуемые изменения (без увеличения задержек)

### A. Вызов establish() в main thread

ConnectivityService может ожидать вызов `establish()` из main thread. Рекомендуется вызывать его через `Handler(Looper.getMainLooper()).post {}` и дожидаться результата (например, через `CountDownLatch`), чтобы корректно применить маршруты при reconnect.

### B. Единый владелец PFD

Передавать созданный PFD из `XrayNativeWrapper` в `GraniVpnService`, чтобы `GraniVpnService.vpnInterface` реально содержал текущий TUN и закрывался в `stopXrayFull()`. Это упростит порядок cleanup и отладку.

### C. Явная синхронизация establish()

Использовать `synchronized(vpnService)` при вызове `establish()` для исключения гонок (по аналогии с известными workaround для sporadic null).

## Проверка после изменений

- `adb shell "ip route get 8.8.8.8"` — после reconnect маршрут должен идти через tun-интерфейс
- Логи tun2socks: должны появляться строки `proxy/socks` при активном трафике

# Отчёт: Конфигурация и reconnect в open-source VPN-сервисах

**Дата:** 2026-02-20  
**Цель:** Анализ подходов к конфигурации и переподключению в аналогах (Amnezia, v2rayNG и др.) для улучшения reconnect в Grani.

---

## 1. Обзор рассмотренных проектов

| Проект | Стек | TUN / режим | Reconnect-подход |
|--------|------|-------------|------------------|
| **v2rayNG** | Kotlin, Xray, Hev Tun / tun2socks | TUN + Xray | Полный перезапуск, 500 ms задержка |
| **AmneziaWG** | WireGuard | TUN (WireGuard kernel) | Reconnect в разработке |
| **Rethink DNS** | Kotlin, Go backend, tun2socks | TUN | Отдельная архитектура (protect/bind) |
| **NekoBoxForAndroid** | Xray | TUN | «Address already in use» при reconnect |

---

## 2. v2rayNG

**Репозиторий:** [2dust/v2rayNG](https://github.com/2dust/v2rayNG)  
**Язык:** Kotlin, Xray core (AndroidLibXrayLite)

### 2.1. Конфигурация

- Конфиг: JSON, генерируется из ProfileItem (`V2rayConfigManager.getV2rayConfig`)
- Поддержка: VLESS, VMess, Trojan, Shadowsocks, Hysteria2, WireGuard
- Маршруты: через `custom_routing_*` и `ROUTED_IP_LIST`
- VPN Builder: `configureNetworkSettings()`, `configurePerAppProxy()`, `configurePlatformFeatures()`

### 2.2. Reconnect (MSG_STATE_RESTART)

```kotlin
// V2RayServiceManager.kt
AppConfig.MSG_STATE_RESTART -> {
    Log.i(AppConfig.TAG, "Restart Service")
    serviceControl.stopService()
    Thread.sleep(500L)
    startVService(serviceControl.getService())
}
```

- Выполняется полный цикл: stop → 500 ms пауза → start
- Нет «soft reconnect» (attachTun) — каждый раз полный рестарт сервиса

### 2.3. Порядок при остановке

```kotlin
// V2RayVpnService.stopAllService()
// Важно: stopSelf() ПЕРЕД mInterface.close()
stopSelf()
try {
    mInterface.close()
} catch (e: Exception) { ... }
```

Комментарий в коде: если `stopSelf()` вызывать после `mInterface.close()`, core не освобождает порт и при следующем старте возникает «port in use».

### 2.4. Вызов establish()

- `builder.establish()` вызывается в `configureVpnService()` из `onStartCommand` (main thread сервиса)
- Нет обёртки типа `establishOnMainThread` — всё выполняется в потоке `onStartCommand`

### 2.5. TUN: Hev Tun vs Xray Core TUN

- При включённом Hev Tun используется альтернативный TUN (TProxyService)
- Проблемы Xray Core TUN: отсутствие sockopt-маркировки, sniffing, возможные бесконечные петли при Direct-роутинге
- В Grani используется tun2socks поверх TUN — архитектура ближе к Hev Tun

---

## 3. Amnezia / AmneziaWG

**Репозиторий:** [amnezia-vpn/amneziawg-android](https://github.com/amnezia-vpn/amneziawg-android)

### 3.1. Реализация reconnect

- Issue #1933: запрос на автоматический reconnect с exponential backoff — **не реализован**
- Issue #47: watchdog для автоперезапуска при убийстве процесса — **открыт**
- Issue #52: VPN не стартует после перезапуска приложения
- Issue #38: нежелательный автоподключение после reboot

### 3.2. Вывод

AmneziaWG на Android не предлагает готовых решений для reconnect; проблемы с восстановлением соединения тоже есть.

---

## 4. NekoBoxForAndroid

**Проблемы reconnect:**

- «Failed: listen tcp 127.0.0.1:6450: bind: address already in use»
- Часто требуется force-stop приложения перед повторным подключением

Это указывает на типичную ситуацию: порты/ресурсы не успевают освободиться до следующего старта.

---

## 5. Rethink DNS (BraveVPNService)

**Репозиторий:** [celzero/rethink-app](https://github.com/celzero/rethink-app)

### 5.1. Архитектура

- Go backend (firestack), Kotlin `VpnService`
- `protect()`, `bind()`, `ConnectionMonitor`, `GoVpnAdapter`
- Использует `protectDispatcher`, `bind4Dispatcher`, `bind6Dispatcher` для `protect()` и bind-операций

### 5.2. Особенности

- Подробная работа с `protect()` и bind к underlying network
- Сложная модель маршрутизации (routers, proxies, DNS)
- Для Grani малоприменимо напрямую — иной стек (Go + Kotlin, без Xray)

---

## 6. Android VpnService: общие моменты

### 6.1. establish() и ConnectivityService

- `Builder.establish()` внутри вызывает `IConnectivityManager` (ConnectivityService)
- Документация не требует main thread явно, но известны проблемы на отдельных устройствах
- Stack Overflow и отчёты: на части устройств `establish()` из background thread может давать `null` или некорректную маршрутизацию

### 6.2. Порядок при остановке

- Рекомендуется: drain старого дескриптора → close
- v2rayNG показывает: `stopSelf()` должен вызываться до `mInterface.close()`, иначе порты могут не освободиться

---

## 7. Сравнение с Grani

| Аспект | v2rayNG | Grani |
|--------|---------|-------|
| Задержка перед reconnect | 500 ms | 500 ms (`RECONNECT_DELAY_BEFORE_ESTABLISH_MS`) |
| Вызов establish() | main (onStartCommand) | main thread через `establishOnMainThread()` |
| Soft reconnect (attachTun) | Нет | Есть для in-process (attachTun без рестарта Xray) |
| Порядок stop | stopSelf → close | cleanup → close |
| TUN-подход | Hev Tun или Xray TUN | tun2socks + TUN |

### Что уже есть в Grani

1. `establishOnMainThread()` — `Handler(Looper.getMainLooper()).post`
2. `RECONNECT_DELAY_BEFORE_ESTABLISH_MS = 500`
3. `RECONNECT_WINDOW_MS = 5000` для распознавания быстрого reconnect
4. attachTun для soft reconnect (без рестарта Xray)

### Возможные улучшения по аналогии

1. **Порядок stop**
   - В v2rayNG: `stopSelf()` до `mInterface.close()`
   - В Grani — проверить, что cleanup и закрытие fd выполняются в согласованном порядке и до повторного `establish()`

2. **Задержка**
   - v2rayNG: фиксированные 500 ms при MSG_STATE_RESTART
   - На проблемных устройствах (Oplus) — рассмотреть 800–1500 ms или device-specific настройки

3. **Полный restart вместо soft reconnect**
   - v2rayNG всегда делает полный stop + start
   - При стабильных проблемах с attachTun можно добавить опцию «force full restart on reconnect» (как в v2rayNG)

4. **MTU и буферы**
   - v2rayNG использует `SettingsManager.getVpnMtu()`
   - В Grani — MTU 1280 в конфиге; стоит убедиться, что он реально применяется к TUN и tun2socks

5. **Protect-сокеты**
   - В Rethink DNS есть `protectDispatcher` для `protect()`
   - В Grani — убедиться, что все сокеты Xray и tun2socks защищены через `protect()` (особенно на Oplus/ColorOS)

---

## 8. Рекомендации

### Краткосрочные

1. Убедиться, что `stopSelf()` вызывается до закрытия TUN (или эквивалентно: что connectivity subsystem успевает освободить ресурсы до `establish()`).
2. Добавить опцию или device-specific флаг: при reconnect всегда выполнять полный restart (как в v2rayNG).
3. Для Oplus: протестировать увеличение задержки до 800–1000 ms перед `establish()`.

### Среднесрочные

1. Проверить применение MTU к TUN и tun2socks.
2. Оценить Hev Tun как альтернативу, если проблемы с Xray TUN сохранятся.
3. Исследовать увеличение буферов TUN (TUNSETSNDBUF/TUNSETRCVBUF), где это поддерживается.

### Ссылки

- [v2rayNG V2RayVpnService.kt](https://github.com/2dust/v2rayNG/blob/master/V2rayNG/app/src/main/java/com/v2ray/ang/service/V2RayVpnService.kt)
- [v2rayNG V2RayServiceManager.kt](https://github.com/2dust/v2rayNG/blob/master/V2rayNG/app/src/main/java/com/v2ray/ang/handler/V2RayServiceManager.kt)
- [AmneziaWG Android](https://github.com/amnezia-vpn/amneziawg-android)
- [Rethink DNS BraveVPNService](https://github.com/celzero/rethink-app/blob/master/app/src/main/java/com/celzero/bravedns/service/BraveVPNService.kt)

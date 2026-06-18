# Анализ: rx: 0, tx: 0 и быстрый disconnect → reconnect

**Дата:** 17.02.2026  
**Запрос:** Проверить XrayNativeWrapper/setSession, частоту rx:0,tx:0 при быстром disconnect→reconnect, необходимость паузы и порядок остановки TUN/Xray.

---

## 1. setSession — уже уникальный

### XrayNativeWrapper.kt (строка 353)

```kotlin
.setSession("GRANI-${System.currentTimeMillis()}")
```

### VpnService.kt (BoringHTTPS, строка 831)

```kotlin
.setSession("GRANI-BoringHTTPS-${System.currentTimeMillis()}")
```

**Вывод:** Уникальный session на каждый connect уже есть. Ошибки rx:0,tx:0 при наличии этих изменений требуют отдельного разбора.

---

## 2. Порядок остановки (TUN и Xray)

### XrayNativeWrapperTun2Socks.stopVpn() (строки 115–142)

1. `Tun2Socks.resetForRestart()` — сразу сбрасывает `isInitialized = false`
2. `tun2socksRunning.set(false)`, `Tun2Socks.stopTun2Socks()`
3. `tun2socksThread.join(TUN2SOCKS_JOIN_MS)` — ожидание до 3.5 с
4. `delegate?.stopVpn()` — остановка Xray и закрытие TUN

### XrayNativeWrapper.stopVpn()

1. Остановка Xray (`stopXrayMethod.invoke`)
2. `xrayThread.join(2000)`
3. `cleanup()` — закрытие TUN fd

**Вывод:** Порядок корректен: сначала tun2socks, потом Xray и TUN. Это нужно, чтобы избежать гонки при закрытии TUN fd (pthread_mutex on destroyed mutex).

---

## 3. Порядок запуска (TUN и Xray)

### XrayNativeWrapper.startVpn()

1. Создание TUN интерфейса (`builder.establish()`)
2. `Thread.sleep(200)` — время ядру применить маршруты
3. `onTunCreated(vpnInterface)` → `startTun2SocksBridge`
4. Параллельно запуск Xray-core в отдельном потоке

### startTun2SocksBridge()

1. `Thread.sleep(DELAY_BEFORE_TUN2SOCKS_MS)` — 700 ms, чтобы Xray успел открыть SOCKS порт
2. `Tun2Socks.startTun2Socks(...)`

**Вывод:** Очередность и задержки (200 ms для TUN, 700 ms перед tun2socks) выглядят разумно.

---

## 4. Быстрый disconnect → reconnect: гонки

### Сериализация intent’ов на Android

- `startService(ACTION_STOP)` и `startService(ACTION_START)` обрабатываются тем же экземпляром `GraniVpnService`
- `onStartCommand` вызывается последовательно на главном потоке
- Новый intent не обрабатывается, пока текущий `onStartCommand` не завершится

Для Quick Tile:

- Disconnect → ACTION_STOP
- Reconnect → ACTION_START
- Сначала обрабатывается STOP (stopVpn до ~3.5 с), затем START. Новый start выполнится после полной остановки предыдущей сессии.

### Flutter: 2‑секундная пауза

```dart
static const Duration _minDelayAfterDisconnect = Duration(seconds: 2);
```

- `_lastDisconnectCompletedAt` ставится при завершении Flutter `disconnect()` (после `_disconnectXray()` и `await remoteDisconnect`)
- При connect проверяется, прошло ли 2 секунды с момента disconnect

Важно: platform channel `disconnect` возвращается сразу после `stopService()` (до фактической остановки на Android). Фактическая остановка tun2socks может занимать до 3.5 с.

При этом:

- `connect()` вызывает `startService(ACTION_START)`, который ставится в очередь
- Сервис ещё может обрабатывать ACTION_STOP
- ACTION_START будет обработан только после возврата из `onStartCommand` для ACTION_STOP
- Поэтому новый start не начнётся, пока не закончится stopVpn (в т.ч. join tun2socks)

**Вывод:** Реальная сериализация обеспечивается обработкой intent’ов, а не только паузой во Flutter.

---

## 5. Рекомендации

### 5.1 Пауза после disconnect

- Текущее значение `_minDelayAfterDisconnect = 2` с в целом достаточно, т.к. ключевая защита — на стороне Android.
- Для дополнительной страховки можно увеличить до 4 секунд (больше `TUN2SOCKS_JOIN_MS`), если rx:0,tx:0 продолжают проявляться.

### 5.2 Если rx: 0, tx: 0 сохраняется

Дополнительно проверить:

1. **Логи:** `"initialization before done"` — означает повторный вызов `Tun2Socks.initialize()` при `isInitialized == true` (resetForRestart не успел сработать или есть другая точка вызова initialize).
2. **Ошибки libXray** при старте.
3. **Серверный access.log** — есть ли `accepted` с UUID клиента после reconnect (трафик не доходит до сервера или падает до Xray).
4. **VMESS vs VLESS** — в отчётах чаще упоминается VMESS; имеет смысл фиксировать протокол и условия.

### 5.3 Диагностика

Добавить логирование времени полного disconnect (от вызова stop до завершения join) и момента начала start для следующей сессии — для проверки, что между ними есть достаточный зазор.

---

## 6. Итог

| Компонент             | Статус |
|-----------------------|--------|
| setSession            | Уникальный |
| Порядок stop          | tun2socks → Xray → TUN |
| Порядок start         | TUN → tun2socks (с 700 ms) → Xray |
| Сериализация intent’ов| Работает, новый start не запустится до завершения stop |
| Пауза 2 с во Flutter  | Дополнительная защита |
| Tun2Socks.resetForRestart | Вызывается в начале stop для быстрого reconnect |

При сохраняющихся rx:0,tx:0 нужен разбор по логам (включая серверный access.log) и дополнительная диагностика по времени stop/start.

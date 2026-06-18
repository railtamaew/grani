# Глубокая аналитика: авторизация, подключение к VPN и отключение

**Дата:** 2026-02-19  
**Правило:** `.cursor/rules/vpn-diagnostics.mdc`

---

## 1. Авторизация и подключение к VPN

### 1.1 Цепочка авторизации (клиент)

| Этап | Где | Описание |
|------|-----|----------|
| Токен | `AuthService` | Google OAuth или email; `ensureValidToken()` перед connect |
| Refresh | `AuthService._onDioError` | 401 → refresh-token + retry |
| Ожидание токена | `VpnService._connectStageTokenAndSync` | `authService.waitForTokenLoad()` + `ensureValidToken()` |

### 1.2 Цепочка подключения (connect)

| Этап | Прогресс | Действия |
|------|----------|----------|
| Проверка разрешений | 0% | VPN permission |
| Валидация токена | 10% | Токен, предзагрузка серверов |
| Sync состояния | — | `_syncConnectionState()` (первый connect в сессии) |
| Выбор сервера | 15–20% | `_autoSelectServerAndProtocol()`, регистрация устройства |
| Получение конфига | 30% | Кэш или POST `/vpn/connect`, при 400 «уже подключено» → `_forceDisconnectOnServer` + повтор |
| Парсинг / создание TUN | 40–50% | MTU по типу сети (Wi‑Fi 1500, mobile 1280) |
| Запуск протокола | 60% | Xray (tun2socks + конфиг) или нативный |
| Верификация | 80% | Трафик / IP проверка |
| Подключено | 100% | `_applyTransition(connected)`, старт мониторинга и **смена сети** |

Порты (по правилу): **443** REALITY, **4443** VLESS none, **8443** VMess.

### 1.3 Перекрёстная проверка (по vpn-diagnostics)

- **Сервер:** SSH из контейнера `granivpn_api`, ключ из `servers.ssh_key_content`, проверка `xray`, порты 443/4443/8443, конфиг `/usr/local/etc/xray/config.json`, логи `/var/log/xray/`.
- **Бэкенд:** `docker logs granivpn_api`, БД `servers`, `devices`, генерация `json_config` (порт, tls, протокол).
- **Клиент:** в логах — адрес/порт, routing (direct/proxy), ошибки tun2socks; при `BSocksClient_Init failed` — локальный SOCKS/Xray; при routing loop — трафик на IP VPN через proxy.

---

## 2. Оценка сервиса

- **Плюсы:** явная state machine (VpnConnectionState), этапы connect с прогрессом, обработка 400 «устройство уже подключено», force disconnect при 500, синхронизация состояния с сервером при первом connect в сессии.
- **Минусы:** отключение блокировалось ответом API до 8 с (дерганное состояние и паузы); при смене сети (Wi‑Fi → Мегафон) полное отключение + ожидание API + 800 ms + полный connect — не бесшовно.

---

## 3. Проблема: «дерганное» отключение и паузы

### Причины

1. **Ожидание API** — после локального отключения (tun2socks/Xray) код делал `await remoteDisconnect` с таймаутом **8 с**. Пока API не отвечал, UI оставался в «Отключаемся...».
2. **Ожидание завершения connect** — при нажатии «Отключить» во время подключения — до 8 с (80 × 100 ms).
3. **Пауза отрисовки** — 80 ms после перехода в `disconnecting` (для показа «Отключаемся...») — приемлемо, уменьшено до 50 ms.

### Внесённые изменения

- **API не блокирует UI:** запрос `/vpn/disconnect` выполняется в фоне:
  - при **смене сети** (`_reconnectAfterNetworkChange`) API не ждём вообще — сразу переходим в `disconnected` и запускаем переподключение;
  - при **обычном отключении** ждём ответ API не более **2 с**, затем переходим в `disconnected` (запрос продолжается в фоне).
- Пауза отрисовки «Отключение...» уменьшена с 80 ms до 50 ms.
- Задержка перед переподключением при смене сети снижена с 800 ms до **500 ms** (за счёт того, что отключение больше не ждёт API).

Итог: состояние «Отключаемся...» не зависает на 8 с; при смене сети переподключение начинается быстрее.

---

## 4. WiFi → Мегафон (переподключение)

### Текущее поведение

- `Connectivity().onConnectivityChanged` с debounce 2 с.
- При смене типа сети (wifi ↔ mobile) вызывается `disconnect()` с флагом `_reconnectAfterNetworkChange = true`.
- После завершения disconnect: `Future.delayed(reconnectAfterNetworkChangeDelay, () => connect())`.

### Почему не было «бесшовным»

- Полное отключение включало ожидание API до 8 с.
- Затем 800 ms задержки и полный цикл connect (конфиг, TUN, Xray и т.д.). Итого — длинный разрыв.

### Что сделано для более плавного переключения

1. При смене сети **не ждём** ответ API отключения — сразу переходим в `disconnected` и запускаем `connect()` через 500 ms.
2. Задержка переподключения уменьшена до 500 ms.
3. MTU при connect уже зависит от типа сети (`_selectMtu` по wifi/mobile), поэтому после переподключения используется корректный MTU для новой сети.

Полностью бесшовное переключение без разрыва (без disconnect) потребовало бы поддержки на стороне сервера/протокола (например, один и тот же клиент при смене сети без перевыдачи конфига) и более сложной логики; текущие изменения существенно сокращают время «простоя» при WiFi → мобильный.

---

## 5. Варианты дальнейшей оптимизации

| Вариант | Описание |
|--------|----------|
| Сократить debounce смены сети | Сейчас 2 с; можно 1–1.5 с — быстрее реакция, чуть больше срабатываний при «дрожании» сети. |
| Отдельный короткий таймаут для API disconnect | Сейчас 2 с при обычном отключении; можно вынести в `AppConfig` (например 1.5–2 с). |
| Метрики этапов | Использовать `_lastConnectionTimingMs` и логирование этапов для мониторинга узких мест (sync_state, get_config, local_disconnect). |
| Поведение при 400 после смены сети | Уже обрабатывается: `_forceDisconnectOnServer` + повтор connect. |

---

## 6. Закрытие и сворачивание приложения

При **сворачивании** или **закрытии приложения из списка недавних** VPN **не отключается** — соединение сохраняется.

- **Android:** `GraniVpnService` работает как foreground-сервис. При `onTaskRemoved` (пользователь убрал задачу из recents) сервис отправляет новый `ACTION_START` с сохранённым конфигом, чтобы система не завершила процесс; в `onStartCommand` при уже запущенном VPN (`isRunning`) вызывается только обновление уведомления, **без** вызова `startVpn()` — туннель не перезапускается.
- **Flutter:** при `paused`/`detached` вызывается `_syncConnectionStateOnPause()` — только логирование, без вызова `disconnect()` и без API отключения на сервере.

Явное отключение VPN происходит только по действию пользователя (кнопка «Отключить» в приложении или отключение с Quick Tile).

---

## 7. Файлы изменений

**2026-02-19:**
- `mobile-app/lib/services/vpn_service.dart` — не блокировать UI на API при отключении; при смене сети не ждать API; frameDelayMs 50; использование `AppConfig.disconnectUiWaitMax`, `disconnectWaitConnectMaxAttempts`, `networkChangeDebounceDuration`.
- `mobile-app/lib/config/app_config.dart` — `reconnectAfterNetworkChangeDelay` 500 ms; добавлены `disconnectUiWaitMax` (2 с), `networkChangeDebounceDuration` (1.5 с); `disconnectWaitConnectMaxAttempts` 45 (≈4.5 с).

**2026-02 (доработки по логам и смене сети):**
- `vpn_service.dart` — явное логирование [reconnect] (смена сети, disconnect начат/завершён, connect старт); cooldown 2 с между переподключениями по смене сети (`reconnectMinIntervalAfterNetworkChange`); флаг `_connectTriggeredByNetworkChange` и `_lastReconnectConnectStartedAt`.
- `app_config.dart` — `reconnectMinIntervalAfterNetworkChange` 2 с; `logsSendTimeout` 5 с; `logsSendRetryDelay` 1 с.
- `connection_logger.dart` — таймаут отправки логов 5 с, одна повторная попытка при таймауте/сетевой ошибке.
- `auth_service.dart` — одна повторная попытка bootstrap по тому же URL при таймауте/сетевой ошибке (задержка 2 с).

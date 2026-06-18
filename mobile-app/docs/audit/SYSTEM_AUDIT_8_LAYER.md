# Системный аудит архитектуры VPN-клиента (8 слоёв)

**Машина состояний (переходы, UI-слой, пути Tile/handover):** см. [VPN_STATE_MACHINE.md](VPN_STATE_MACHINE.md).

Документ фиксирует **источники истины**, **границы согласованности**, типовые **сценарии деградации** и **архитектурные направления** для стека:

`Flutter UI` → `MethodChannel` → `GraniVpnService` → `TUN` → `tun2socks` / `Xray` → `API (multi-base)` → интернет.

Кодовые опоры: [`lib/services/vpn_service.dart`](../../lib/services/vpn_service.dart), [`lib/core/api/preferred_route_storage.dart`](../../lib/core/api/preferred_route_storage.dart), [`lib/core/api/api_client.dart`](../../lib/core/api/api_client.dart), [`lib/services/auth_service.dart`](../../lib/services/auth_service.dart), [`android/.../VpnService.kt`](../../android/app/src/main/kotlin/com/granivpn/mobile/VpnService.kt), [`lib/services/connection_logger.dart`](../../lib/services/connection_logger.dart).

---

## 1. Распределённый аудит (MASTER)

### Канонические источники истины

| Аспект | Первичный источник | Вторичный / синхронизация |
|--------|-------------------|---------------------------|
| «Пользователь нажал подключить» | `VpnService.connect` / `_executeConnect`, `_connectionSessionId` | Логи `ConnectionLogger` с тем же id |
| Состояние UI VPN | `VpnConnectionState` + `VpnUiSessionState` через `_applyTransition` | `syncConnectionStateWithNative()` сверяет с `NativeVpnService.getStatus()` |
| Туннель реально поднят | Натив: `GraniVpnService.isVpnRunning` / установка после успешного старта Xray | Dart не считает `connected` до `_connectStageOnSuccess` после verify |
| Конфиг Xray | Secure storage + API `create-client` / GET config в `_connectXray` | Кэш инвалидируется при `clearXrayConfigCache` и ошибках |

### Границы временного рассинхрона (ожидаемо)

- Между «натив поднял TUN» и «Dart выставил `connected`» — окно verify (до ~6 с) и вызовы `MethodChannel`.
- После handover Wi‑Fi↔LTE натив делает `stopVpn` + рестарт; Dart может кратко опрашивать статус — см. `syncConnectionStateWithNative`.
- Quick Tile без Flutter: состояние только натив + prefs последнего конфига; Dart узнаёт при следующем resume.

### Недетерминизм (не баг сам по себе)

- Параллельные 401 → несколько потоков могли вызывать `refreshAccessToken` до single-flight; **исправлено**: см. `AuthService.refreshAccessToken` (coalescing).
- Handover и параллельный пользовательский disconnect — см. флаги `networkReconnectInProgress` в нативе.

### Воспроизведение (матрица)

| Сценарий | Что смотреть |
|----------|----------------|
| Wi‑Fi → LTE при VPN ON | logcat `[NET_MONITOR]`, `[CORRELATION] connection_session_id=`, Dart `connection_flow_type` |
| Убить app из recents при VPN | натив `onTaskRemoved`, prefs конфига, следующий старт Tile |
| Плохой первый API URL | `PreferredRouteStorage.reportRouteFailure`, fallback в `ApiClient` |

### Архитектурная фиксация

- Каноническое «VPN активен для пользователя»: **Dart `VpnConnectionState.connected` после verify**, согласованное с нативом при resume через `syncConnectionStateWithNative`.
- Документировать в UI: состояния «reconnecting» при нативном handover без полного прохода `connect()` в Dart.

---

## 2. Flutter + UI state

### Где состояние централизовано

- Основной поток: `Provider` + `VpnService.notifyListeners`, `VpnShellUiHelpers.friendlyProgressMessage`.
- Отдельные экраны маппят `VpnUiSessionState` (например trial) — источник всё равно `VpnService`.

### Риск рассинхрона

- Прямой опрос натива в UI: [`split_tunnel_screen.dart`](../../lib/screens/split_tunnel_screen.dart) вызывает `NativeVpnService.getStatus()` для текста — **намеренно** второй источник; держать редким и документированным.
- Смена локали: `LocaleController` → rebuild `MaterialApp` — **не меняет** туннель; возможна только визуальная «мигание» прогресса.

### Рекомендации

- Новые экраны: не вводить локальный `bool vpnOn`; использовать `context.watch<VpnService>()`.
- При шторме `notifyListeners` при необходимости — debounce на уровне виджета (точечно), не глобально без метрик.

---

## 3. Android VpnService + lifecycle

### Ключевые механизмы

- [`VpnService.kt`](../../android/app/src/main/kotlin/com/granivpn/mobile/VpnService.kt): `ACTION_START`/`STOP`, `ServiceState`, игнор старта при занятости (`start_ignored_busy_state`), `onTaskRemoved` рестарт с последним конфигом.
- [`VpnPlugin.kt`](../../android/app/src/main/kotlin/com/granivpn/mobile/VpnPlugin.kt): `connect` из Flutter с `connection_session_id` + `source`, ожидание подтверждения запуска.
- Quick Tile: [`QuickTileService.kt`](../../android/app/src/main/kotlin/com/granivpn/mobile/QuickTileService.kt) — конфиг из prefs, `source = quick_tile`.

### Корреляция

- Лог `[CORRELATION] connection_session_id=… start_source=…` при каждом START; handover подставляет сохранённый id.

### Воспроизведение

- Swipe away из recents + VPN ON → проверить восстановление и лог `task_removed_restart`.
- Tile без Activity → только нативный путь.

---

## 4. Network / TUN / Xray

### Поведение

- `handleUnderlyingNetworkChanged`: stop, пауза, `startService` с MTU Wi‑Fi (1500) / mobile (1280).
- Со стороны Dart: `_selectMtu` по типу сети при первичном connect.

### Симптомы сети vs баг приложения

- `broken pipe` / `connection reset` на установленных TCP после смены радио — **норма**; критерий — восстановление туннеля и новый трафик.

### Рекомендации

- Health: уже есть verify и `traffic_first_seen` в логах; при расширении — latency до exit-ноды (отдельная задача).

---

## 5. Config + cache

### Xray

- [`xray_connection_handler.dart`](../../lib/services/xray_connection_handler.dart): кэш по `serverId` + протокол, валидация порта.
- Холодный путь: `_connectStageGetConfig` для Xray не подставляет кэш на этапе get_config — конфиг в `_connectXray()`.
- Инвалидация: `clearXrayConfigCache`, смена сервера/протокола, ошибки verify.

### Версионирование записи (клиент)

- В secure-кэше Xray сохраняются `cache_v: 1`, `cached_at_ms` и `config` (+ `client_id` при наличии) — см. `StorageXrayConfigCache.set` в [`xray_connection_handler.dart`](../../lib/services/xray_connection_handler.dart). Расширение `revision` с бэкенда — при появлении поля в API.

### Рекомендации

- При появлении revision от API — добавить поле рядом с `cached_at_ms` и сравнивать при чтении.

---

## 6. Auth + device limit

### Механизмы

- `AuthService`: 401 interceptor → `refreshAccessToken` (single-flight), `ensureValidToken`; после успешного refresh вызываются слушатели (`addAccessTokenRefreshedListener`), в т.ч. `VpnService` — сверка натива и `/vpn/status` при активном VPN.
- Email: `_authEmailSerial` для send/verify; гигиена `_authCodeRequestId` при сбоях send-code.

### Идентичность устройства

- `device_id` через fingerprint / `ConnectionLogger.onDeviceIdResolved` — цепочка обновления в `VpnService` при резолве.

---

## 7. API routing / backend

### Клиент

- [`PreferredRouteStorage`](../../lib/core/api/preferred_route_storage.dart): preferred URL, health cooldown, `lastSuccessfulRouteForLogging` для логов.
- [`ApiClient`](../../lib/core/api/api_client.dart): перебор баз на GET/POST при ошибках маршрута.

### Риск

- Разные инстансы API с расходящейся репликацией могут дать разные `/vpn/status` — **операционный** риск, не только клиента.

### Рекомендации

- Sticky-предпочтение successful base уже есть; алерты на бэкенде при дивергенции статусов.

---

## 8. Логи и наблюдаемость

См. отдельный документ: [`OBSERVABILITY_RUNBOOK.md`](OBSERVABILITY_RUNBOOK.md) и [`METRICS_AND_OBSERVABILITY.md`](../METRICS_AND_OBSERVABILITY.md).

---

## Порядок работ (как в плане)

1. Зафиксировать карту источников истины (этот документ).
2. Включить наблюдаемость по runbook (корреляция уже в коде).
3. Слои 2–3: UI + native — по инцидентам сверять logcat и Dart-логи по `connection_session_id`.
4. Слои 4–5: туннель и кэш — отделять радио от дефектов конфига.
5. Слои 6–7: auth и маршруты — single-flight refresh, мониторинг баз.

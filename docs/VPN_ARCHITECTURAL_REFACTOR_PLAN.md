# Архитектурный план: радикальное упрощение VPN

## 1. Удаление нерабочих протоколов

**Удаляем полностью:** WireGuard, GraniWG, OpenVPN over Cloak.

**Причина:** В современных реалиях не работают. Оставляем только Xray (VLESS/VMess/Reality) и при необходимости Boring HTTPS.

### 1.1 Mobile App (Flutter)

| Файл | Действие |
|------|----------|
| `lib/models/vpn_protocol.dart` | Удалить `wireguard`, `graniwg`, `openvpnCloak` из enum |
| `lib/services/vpn_service.dart` | Удалить все ветки `_connectWireGuard`, `_disconnectWireGuard`, `_applyWireGuardConfig`, `_applyGRANIWGConfig`, `_connectOpenVPNCloak`, `_disconnectOpenVPNCloak`, `_applyOpenVPNCloakConfig`, `_connectWithFallbackProtocol` для wg/graniwg/ovpn |
| `lib/widgets/bottom_sheets/protocol_selector_bottom_sheet.dart` | Оставить только xray + boringHttps |
| `lib/widgets/protocol_selector_button.dart` | Адаптировать |
| `lib/protocols/graniwg/` | Удалить директорию |
| `lib/protocols/openvpn_cloak/` | Удалить директорию |
| Дефолтный протокол | С `wireguard` на `xrayReality` |

### 1.2 Android Native

| Файл | Действие |
|------|----------|
| `VpnService.kt` | Удалить WireGuardAdapter, логику detectProtocol для wg/graniwg, stopWireGuard, AmneziaWG |
| WireGuard-зависимости | Оставить (AmneziaWG может использоваться для Boring HTTPS) или убрать, если Boring HTTPS не нужен |

### 1.3 Backend

| Файл | Действие |
|------|----------|
| `connection_orchestrator.py` | Убрать ветки connect_device/disconnect_device для wireguard, openvpn_cloak |
| `vpn_operations_service.py` | Убрать обработку wireguard/graniwg/openvpn_cloak |
| `api/vpn.py` | Эндпоинт /vpn/connect — оставить только для Xray/Boring (или упростить до create-client для Xray) |
| `wireguard_manager.py`, `openvpn_manager.py` | Оставить как есть (могут использоваться в других скриптах), но не вызывать из orchestrator |
| База данных | `supportedProtocols` на серверах — убрать wireguard, graniwg, openvpn_cloak из seed/конфигов |

---

## 2. Анализ Xray: точки обрыва соединения

### 2.1 Цепочка Xray (Flutter → Native)

```
connect() → _connectXray() → _applyXrayConfig() → NativeVpnService.connect()
  → GraniVpnService.startVpn() → XrayAdapter.start() → processXrayPackets()
  → XrayNativeWrapperTun2Socks.startVpn()
    → XrayNativeWrapper.startVpn() [создаёт TUN, запускает libXray]
    → onTunCreated → startTun2SocksBridge(pfd) [700ms задержка, затем Tun2Socks]
```

### 2.2 Возможные точки обрыва

| Точка | Описание | Вероятность |
|-------|----------|-------------|
| **create-client таймаут** | SSH на сервере, reload Xray — 15–25 с | Высокая при первом connect |
| **libXray runXray** | Нативный код libXray — парсинг конфига, TLS handshake Reality | Средняя |
| **tun2socks → SOCKS** | tun2socks подключается к 127.0.0.1:10808 до того, как libXray поднял SOCKS | Высокая при reconnect |
| **TUN fd при втором establish** | Android VpnService.Builder.establish() — повторный вызов после stopVpn | Высокая (трафик не идёт в tun2socks) |
| **_verifyConnection** | Проверка трафика — если туннель ещё не поднялся, считаем failure и disconnect | Средняя |
| **Reality probe / connection monitoring** | Фоновые проверки — могут вызывать disconnect при ложном negative | Низкая |

### 2.3 Рекомендации по Xray

1. **Второй connect:** Полный цикл stopVpn → startVpn. LibXray и tun2socks пересоздаются. Проблема: TUN при втором establish не маршрутизирует трафик. Нужно проверить порядок: `Builder.establish()` → `tun2socks` → libXray уже слушает SOCKS.
2. **Увеличить DELAY_BEFORE_TUN2SOCKS_MS** — не рекомендуется (пользователь против пауз). Вместо этого: гарантировать, что libXray поднял SOCKS до вызова tun2socks (callback после успешного runXray).
3. **Упростить _verifyConnection при reconnect из кэша:** Дольше ждать трафик (3 с вместо 0.4+0.8 с) или не делать disconnect при первой неудаче.

---

## 3. Упрощение connect()

### 3.1 Текущие этапы (8 штук)

1. **permissions** — VPN permission
2. **device_and_network** — device_id, MTU
3. **token_and_sync** — токен, servers, sync (уже отключен), ConnectionLogger
4. **select_server** — autoSelectServerAndProtocol, logConnectionStart
5. **get_config** — для Xray: no-op (config = null)
6. **apply_protocol** — _connectXray (create-client или кэш) + _applyXrayConfig + NativeVpnService
7. **verify** — трафик, IP, Reality probe
8. **on_success** — transition, мониторинг, логирование

### 3.2 Предлагаемая упрощённая цепочка (Xray-only)

**4 этапа вместо 8:**

1. **prepare** — permissions + token + server + device_id (если нужен) + MTU. Всё в одном проходе, без sync.
2. **get_config** — только для Xray: кэш или create-client. Для Xray-only get_config и apply объединены в _connectXray.
3. **apply** — _applyXrayConfig → NativeVpnService.connect.
4. **verify** — только трафик (убрать IP check, Reality probe при первом connect).

### 3.3 Что убрать / объединить

| Убрать | Обоснование |
|--------|-------------|
| _syncConnectionState | Уже отключено. Не вызывать. |
| _connectStageSelectServerAndLogStart как отдельный этап | Объединить с prepare: autoSelectServer в начале. |
| logConnectionStart до connect | Перенести в on_success или убрать (не блокируем connect). |
| ConnectionLogger.setCredentials в connect | Можно вызвать при первом успешном connect. |
| Reality probe в _verifyConnection | Упростить: только трафик. Probe — отдельный фоновый таймер после connected. |
| _connectWithFallbackProtocol | Удалить вместе с wg/graniwg/ovpn. |
| maxRetries = 3 с retryDelay 1 с | Уменьшить до 1 retry или убрать — упростить. |
| _connectionProgress (8 состояний) | Сократить до 3–4: preparing, connecting, verifying, connected. |
| PerfLogger, _logConnectionStage | Оставить для отладки, но не блокировать. |

### 3.4 Минимальный connect (псевдокод)

```dart
Future<bool> connect() async {
  if (_isConnected || _isConnecting || _disconnectInProgress) return false;
  if (!_selectedProtocol.isImplemented) return false;

  _connectInProgress = true;
  _applyTransition(connecting);
  try {
    // 1. Prepare
    if (!await requestVpnPermission()) throw VpnPermissionException(...);
    final token = await _getToken();  // ensureValidToken + getAuthToken
    if (token.isEmpty) throw Exception('Авторизация');
    if (_deviceId == null) await _loadDeviceId();
    await _autoSelectServerAndProtocol();
    if (_selectedServer == null) throw Exception('Нет сервера');
    _lastMtu = _selectMtu(await _getNetworkTypeLabel());

    // 2. Config + Apply (для Xray — всё в _connectXray)
    final ok = await _connectXray(token);
    if (!ok) return false;

    // 3. Verify
    if (!await _verifyTrafficOnly()) {
      await _disconnectXray();
      throw Exception('Проверка трафика не пройдена');
    }

    _applyTransition(connected);
    _startTrafficStatsMonitoring();
    return true;
  } finally {
    _connectInProgress = false;
  }
}
```

---

## 4. План реализации

1. **Удаление протоколов** — mobile app (vpn_protocol, vpn_service, UI), backend (orchestrator, vpn_operations), Android (WireGuardAdapter).
2. **Упрощение connect** — объединить этапы, убрать sync, fallback, избыточные проверки.
3. **Xray** — документировать точки обрыва; при необходимости доработать порядок tun2socks/libXray на нативном слое.

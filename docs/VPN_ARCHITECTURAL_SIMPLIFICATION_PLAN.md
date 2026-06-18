# Архитектурный план упрощения VPN

## 1. Удаление нерабочих протоколов

**Удалить полностью:** WireGuard, GraniWG, OpenVPN over Cloak.

| Компонент | Файлы / места |
|-----------|---------------|
| **Mobile (Flutter)** | VpnProtocol enum, getHandlerFor, _connectWireGuard, _applyWireGuardConfig, _applyGRANIWGConfig, _disconnectWireGuard, _connectOpenVPNCloak, _applyOpenVPNCloakConfig, _disconnectOpenVPNCloak, _WireGuardHandlerDelegate, _OpenVPNCloakHandlerDelegate, protocol selector UI |
| **Mobile (Android)** | WireGuardAdapter, BoringHttpsAdapter (оставить?), stopWireGuard, startWireGuard, AmneziaWG зависимости (можно оставить в проекте, но не использовать) |
| **Backend** | connection_orchestrator._connect_wireguard, disconnect wireguard peer removal, wireguard_manager вызовы, openvpn_manager |
| **Admin panel** | protocol options для wireguard/graniwg/openvpn в UI |

**Оставить:** Xray (VLESS, VMESS, Reality), опционально Boring HTTPS.

---

## 2. Xray: точки обрыва соединения

### 2.1 Цепочка Xray
```
connect() → _connectXray → create-client/кэш → _applyXrayConfig → NativeVpnService.connect
  → VpnPlugin.connectVpn → GraniVpnService.startVpn → XrayAdapter.start
  → processXrayPackets → XrayNativeWrapperTun2Socks.startVpn
  → XrayNativeWrapper (libXray) + tun2socks (TUN → SOCKS 127.0.0.1:10808)
```

### 2.2 Места, где соединение может оборваться

| Место | Причина | Рекомендация |
|-------|---------|--------------|
| **_startNetworkChangeListener** | При смене Wi‑Fi ↔ mobile вызывается `disconnect()` | **Отключить** или сделать опциональным. Смена сети не должна автоматически рвать VPN. |
| **_verifyConnection** | При отсутствии трафика через 600ms+800ms — warning, для Xray ещё IP/DNS проверки. При fail — disconnect. | Упростить: если конфиг применён и NativeVpnService.getStatus() == true — считать успехом. Проверку трафика сделать мягкой (не disconnect при отсутствии). |
| **Connection monitoring** | Timer 10s: если getStatus() false → disconnect + reconnect. _autoReconnectEnabled = false по умолчанию. | Оставить выключенным. |
| **processXrayPackets finally** | При выходе из processXrayPackets (libXray завершился) — stopXray/detachTun | Нормальный lifecycle. |
| **Tun2Socks race** | При втором connect: tun2socks может стартовать до готовности SOCKS libXray | Уже есть DELAY_BEFORE_TUN2SOCKS_MS 700ms. При необходимости увеличить или ждать явного события «SOCKS ready». |
| **Android VPN Builder.establish()** | При втором connect новый TUN — маршрутизация может не применяться | Проверить: возможно, нужно небольшое время после establish перед tun2socks. |

### 2.3 Главные кандидаты на «Reality подключается, потом отключается»
1. **Слушатель смены сети** — при переключении Wi‑Fi/mobile вызывается disconnect.
2. **_verifyConnection** — при нечётком трафике (API в direct) Xray может не показать rx+tx в окне проверки → fail → disconnect.

---

## 3. Упрощение connect()

### 3.1 Текущие этапы (8 шагов)
1. permissions
2. device_id + network + MTU
3. token + **_syncConnectionState** (уже отключён)
4. selectServer + logStart
5. getConfig (кэш или API)
6. applyProtocol
7. **_verifyConnection**
8. onSuccess

### 3.2 Что убрать / упростить

| Этап | Действие | Обоснование |
|------|----------|-------------|
| **device_id** | Оставить, но не блокировать connect при его отсутствии | Бекенд поддерживает connect без device_id (один коннект на user+server+protocol). |
| **syncConnectionState** | Уже отключён | — |
| **selectServer** | Оставить | Нужен сервер. |
| **ConnectionLogger** | Не блокировать connect | logConnectionStart — fire-and-forget. |
| **getConfig** | Для Xray — только create-client или кэш. Убрать ветку WireGuard/OpenVPN. | Упрощение. |
| **verifyConnection** | Сильно упростить: 1) applyProtocol вернул true; 2) NativeVpnService.getStatus() == true → success. Убрать обязательную проверку трафика и IP/DNS с disconnect при fail. | Сейчас при отсутствии трафика и fail активных проверок — disconnect. Это может рвать рабочий туннель (API в direct, трафик идёт позже). |
| **Пауза после disconnect** | Оставить 2 с | Нужна для tun2socks. |
| **Retry 3 попытки** | Можно уменьшить до 1 или 2 | По желанию. |

### 3.3 Целевая упрощённая цепочка
```
connect():
  1. Блокировки: _isConnected || _isConnecting || _disconnectInProgress
  2. Пауза после disconnect (если < 2 с)
  3. permissions
  4. token (валидация)
  5. selectServer (если не выбран)
  6. getConfig (только Xray: create-client или кэш)
  7. applyProtocol (только Xray)
  8. verify: getStatus() == true (без жёсткой проверки трафика)
  9. onSuccess
```

Убрать: device_id загрузка как обязательный шаг, syncConnectionState, ConnectionLogger блокировку (её нет), сложную verifyConnection.

---

## 4. План реализации

### Фаза 1: Удаление протоколов
- [ ] Mobile: убрать wireguard, graniwg, openvpnCloak из VpnProtocol, handler, connect/disconnect
- [ ] Mobile: убрать выбор этих протоколов из UI (protocol_selector)
- [ ] Backend: убрать ветки wireguard/graniwg/openvpn из connection_orchestrator connect/disconnect
- [ ] Backend: упростить supported_protocols — только xray_*

### Фаза 2: Xray и обрывы
- [ ] Отключить _startNetworkChangeListener (или сделать опциональным, по умолчанию выключен)
- [ ] Упростить _verifyConnection: успех если getStatus() && (трафик ИЛИ таймаут 3 с без disconnect)

### Фаза 3: Упрощение connect
- [ ] Убрать _connectStageDeviceAndNetwork как блокирующий (device_id опционально)
- [ ] Упростить _connectStageGetConfig — только Xray
- [ ] Упростить _verifyConnection до минимума
- [ ] Убрать _connectWithFallbackProtocol (больше не нужен без WireGuard)

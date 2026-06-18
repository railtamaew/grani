# Настройка Apple Developer для macOS VPN

## Network Extension capability

Для работы GraniWG (WireGuard) на macOS необходимо включить Network Extension в Apple Developer Portal.

### Шаги

1. Войдите в [Apple Developer Portal](https://developer.apple.com/account/)
2. **Certificates, Identifiers & Profiles** → **Identifiers**
3. Найдите или создайте App ID: `com.granivpn.mobileApp`
4. Включите capability **Network Extensions** (Packet Tunnel)
5. Сохраните и пересоздайте Provisioning Profile

### Entitlements в проекте

Уже добавлены в `macos/Runner/DebugProfile.entitlements` и `Release.entitlements`:

```xml
<key>com.apple.developer.networking.networkextension</key>
<array>
    <string>packet-tunnel</string>
</array>
```

### Распространение вне App Store

Для распространения через Developer ID (не App Store) может потребоваться **System Extension** вместо App Extension. См. [Apple Documentation](https://developer.apple.com/documentation/networkextension).

### Подпись и нотаризация

См. `docs/DESKTOP_DISTRIBUTION.md` для инструкций по подписи и нотаризации.

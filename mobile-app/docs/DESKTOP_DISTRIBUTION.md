# Распространение desktop-приложения GRANI VPN

## Требования

- **Windows**: Flutter SDK, Visual Studio 2022 (Desktop development with C++)
- **macOS**: Flutter SDK, Xcode, Apple Developer Account

## Сборка

### Windows (.exe)

```bash
cd mobile-app
flutter build windows
```

Артефакт: `build/windows/x64/runner/Release/mobile_app.exe`

**Важно**: Приложение должно запускаться с правами администратора для создания VPN-туннеля.

### macOS (.app)

```bash
cd mobile-app
flutter build macos
```

Артефакт: `build/macos/Build/Products/Release/mobile_app.app`

### macOS (.dmg)

После сборки .app:

```bash
# Создание DMG (требует create-dmg или hdiutil)
hdiutil create -volname "GRANI VPN" -srcfolder build/macos/Build/Products/Release/mobile_app.app -ov -format UDZO mobile_app.dmg
```

## Подпись и нотаризация (macOS)

1. **Apple Developer Portal**:
   - Включите Network Extension capability для App ID `com.granivpn.mobileApp`
   - Создайте Distribution Certificate и Provisioning Profile

2. **Подпись**:
   ```bash
   codesign --force --deep --sign "Developer ID Application: YOUR_NAME" mobile_app.app
   ```

3. **Нотаризация** (для распространения вне App Store):
   ```bash
   xcrun notarytool submit mobile_app.dmg --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID --password YOUR_APP_SPECIFIC_PASSWORD
   xcrun stapler staple mobile_app.dmg
   ```

## Структура для пользователей

- **Windows**: распространять `mobile_app.exe` или упаковать в установщик (Inno Setup, NSIS)
- **macOS**: распространять `.dmg` или `.app` в zip

## Bundle ID

- macOS: `com.granivpn.mobileApp` (AppInfo.xcconfig)
- providerBundleIdentifier в wireguard_flutter берётся из PackageInfo.packageName

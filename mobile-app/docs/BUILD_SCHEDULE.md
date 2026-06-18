# План сборок desktop

## Предварительные условия

| Платформа | Требования |
|-----------|------------|
| **Windows** | Хост Windows, Visual Studio 2022 (Desktop C++), Flutter |
| **macOS** | Хост macOS, Xcode, Apple Developer Account, Network Extension capability |

## Порядок сборок

### 1. Windows

```bash
# На Windows-хосте
cd mobile-app
./scripts/build_windows.sh
# или с очисткой:
./scripts/build_windows.sh --clean
```

**Результат**: `build/windows/x64/runner/Release/mobile_app.exe`

**Тестирование**: Запустить от имени администратора, войти, выбрать сервер, GraniWG, подключиться.

---

### 2. macOS

```bash
# На macOS-хосте
cd mobile-app
./scripts/build_macos.sh
# или с DMG:
./scripts/build_macos.sh --dmg
```

**Результат**: `build/macos/Build/Products/Release/mobile_app.app` (и опционально `.dmg`)

**Перед сборкой**: Включить Network Extension в Apple Developer Portal (см. `APPLE_DEVELOPER_SETUP.md`).

**Тестирование**: Запустить .app, войти, GraniWG, подключиться.

---

### 3. Подпись и распространение (macOS)

После успешной сборки и тестирования:

1. Подписать: `codesign --force --deep --sign "Developer ID Application: ..." mobile_app.app`
2. Создать DMG
3. Нотаризовать: `xcrun notarytool submit ...`
4. Staple: `xcrun stapler staple mobile_app.dmg`

---

## CI/CD (будущее)

- **Windows**: GitHub Actions с `windows-latest` runner
- **macOS**: GitHub Actions с `macos-latest` (требует сертификаты в Secrets)
- **Локально**: Запускать скрипты на соответствующих хостах

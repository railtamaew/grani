# Интеграция AmneziaWG (обфускация)

## Текущее состояние

- **Стандартный WireGuard**: работает через `wireguard_flutter` (Windows, macOS)
- **AmneziaWG с обфускацией** (Jc, Jmin, Jmax, S1-S4, H1-H4): в разработке

При получении конфига с параметрами обфускации приложение выдаёт понятную ошибку.

## План интеграции amneziawg-go

### macOS

1. Собрать amneziawg-go для darwin/arm64 и darwin/amd64:
   ```bash
   git clone https://github.com/amnezia-vpn/amneziawg-go
   cd amneziawg-go
   GOOS=darwin GOARCH=arm64 go build -o amneziawg-go-arm64 .
   GOOS=darwin GOARCH=amd64 go build -o amneziawg-go-amd64 .
   ```

2. Разместить бинарники в `mobile-app/bin/amneziawg/macos/` (arm64, amd64)

3. В `_applyAmneziaWGConfig`:
   - Записать конфиг во временный файл
   - Запустить `amneziawg-go -f wg0`
   - Передать конфиг через UAPI (wg setconf или аналог)

### Windows

amneziawg-go не собирается для Windows (`//go:build !windows`). Используется amneziawg-windows-client — отдельное приложение. Интеграция потребует:
- Либо встраивание сервиса из amneziawg-windows-client
- Либо запуск совместимого `awg-quick.exe` в headless/CLI-режиме

Текущий desktop-шаг:
- Windows Flutter runner регистрирует MethodChannel `com.granivpn.mobile/vpn`;
- `connectAmneziaWg` записывает конфиг в `%LOCALAPPDATA%\GRANI\grani-awg.conf`;
- runner ищется в `GRANI_AWG_QUICK`, затем в `data/flutter_assets/bin/amneziawg/windows/awg-quick.exe`, затем рядом с exe;
- если runner не найден, возвращается явная ошибка `WINDOWS_AWG_RUNNER_MISSING`;
- обычный WireGuard не используется как fallback, чтобы не сломать GRANIwg/AmneziaWG obfuscation-параметры.

## Бэкенд

Бэкенд возвращает AmneziaWG-конфиг, когда `server.graniwg_enabled` и `obfuscation_type == "amneziawg"`. Параметры Jc, Jmin, Jmax, S1-S4, H1-H4 добавляются в секцию [Interface].

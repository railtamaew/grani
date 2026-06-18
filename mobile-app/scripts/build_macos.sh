#!/bin/bash

# Сборка macOS desktop (.app и опционально .dmg)
# Запускать на macOS
# Использование: ./scripts/build_macos.sh [--clean] [--dmg]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_LOG="$PROJECT_DIR/build_info.log"

cd "$PROJECT_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$BUILD_LOG"
}

CLEAN_BUILD=false
CREATE_DMG=false
for arg in "$@"; do
    [[ "$arg" == "--clean" ]] && CLEAN_BUILD=true
    [[ "$arg" == "--dmg" ]] && CREATE_DMG=true
done

log "=========================================="
log "Сборка macOS desktop (GraniWG)"
log "=========================================="

if [[ "$CLEAN_BUILD" == true ]]; then
    log "Очистка проекта..."
    flutter clean
fi

log "Получение зависимостей..."
flutter pub get

log "Сборка macOS release..."
flutter build macos --release

APP_PATH="$PROJECT_DIR/build/macos/Build/Products/Release/mobile_app.app"
if [[ ! -d "$APP_PATH" ]]; then
    log "Ошибка: .app не найден"
    exit 1
fi

log "Сборка .app завершена: $APP_PATH"

if [[ "$CREATE_DMG" == true ]]; then
    log "Создание DMG..."
    DMG_PATH="$PROJECT_DIR/build/macos/Build/Products/Release/mobile_app.dmg"
    hdiutil create -volname "GRANI VPN" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH"
    log "DMG создан: $DMG_PATH"
fi

log "Перед распространением: включите Network Extension в Apple Developer Portal для App ID com.granivpn.mobileApp"
exit 0

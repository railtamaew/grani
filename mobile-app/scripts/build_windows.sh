#!/bin/bash

# Сборка Windows desktop (.exe)
# Запускать на Windows: flutter build windows поддерживается только на Windows
# Использование: ./scripts/build_windows.sh [--clean]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_LOG="$PROJECT_DIR/build_info.log"

cd "$PROJECT_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$BUILD_LOG"
}

CLEAN_BUILD=false
[[ "$1" == "--clean" ]] && CLEAN_BUILD=true

log "=========================================="
log "Сборка Windows desktop (GraniWG)"
log "=========================================="

AWG_QUICK_PATH="$PROJECT_DIR/bin/amneziawg/windows/awg-quick.exe"
if [[ -f "$AWG_QUICK_PATH" ]]; then
    log "Windows GRANIwg runner найден: $AWG_QUICK_PATH"
else
    log "Внимание: Windows GRANIwg runner не найден: $AWG_QUICK_PATH"
    log "Приложение соберется, но подключение вернет WINDOWS_AWG_RUNNER_MISSING."
    log "Для dev-теста можно задать переменную GRANI_AWG_QUICK с полным путем к совместимому awg-quick.exe."
fi

if [[ "$CLEAN_BUILD" == true ]]; then
    log "Очистка проекта..."
    flutter clean
fi

log "Получение зависимостей..."
flutter pub get

log "Сборка Windows release..."
flutter build windows --release

EXE_DIR="$PROJECT_DIR/build/windows/x64/runner/Release"
EXE_PATH="$EXE_DIR/mobile_app.exe"

if [[ -f "$EXE_PATH" ]]; then
    log "Сборка завершена: $EXE_PATH"
    log "Запуск: от имени администратора (для VPN)"
    exit 0
else
    log "Ошибка: exe не найден"
    exit 1
fi

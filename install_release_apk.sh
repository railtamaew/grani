#!/bin/bash
# Скрипт для установки release APK на устройство для локального тестирования
# Используется для тестирования XRay протоколов до активации upload key

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Настройка окружения
export PATH=$PATH:/opt/android-sdk/platform-tools:/opt/android-sdk/cmdline-tools/latest/bin
export ANDROID_HOME=/opt/android-sdk
export ANDROID_SDK_ROOT=/opt/android-sdk

PROJECT_DIR="/opt/grani"
MOBILE_APP_DIR="$PROJECT_DIR/mobile-app"
OUTPUT_DIR="$PROJECT_DIR/release_apks"
PACKAGE_NAME="com.granivpn.mobile"
LOG_DIR="$PROJECT_DIR/logs"

echo "=========================================="
echo "  Установка RELEASE APK на устройство"
echo "=========================================="
echo ""

# 1. Проверка устройств
print_info "[1/5] Проверка устройств..."
adb start-server
DEVICE=$(adb devices | grep -v "List" | grep "device$" | head -1 | awk '{print $1}')

if [ -z "$DEVICE" ]; then
    print_error "Устройство не найдено"
    echo ""
    echo "Доступные устройства:"
    adb devices
    exit 1
fi

DEVICE_MODEL=$(adb -s "$DEVICE" shell getprop ro.product.model 2>/dev/null || echo "Unknown")
print_success "Устройство: $DEVICE ($DEVICE_MODEL)"
echo ""

# 2. Поиск APK
print_info "[2/5] Поиск APK файла..."

# Сначала ищем в OUTPUT_DIR (версионированные)
APK=$(ls -t "$OUTPUT_DIR"/app-release-v*.apk 2>/dev/null | head -1)

# Если не найден, ищем в build директории
if [ -z "$APK" ]; then
    APK="$MOBILE_APP_DIR/build/app/outputs/flutter-apk/app-release.apk"
fi

if [ ! -f "$APK" ]; then
    print_error "APK не найден"
    echo ""
    echo "Доступные APK файлы:"
    ls -lh "$OUTPUT_DIR"/*.apk 2>/dev/null || echo "  (нет файлов в $OUTPUT_DIR)"
    ls -lh "$MOBILE_APP_DIR/build/app/outputs/flutter-apk/"*.apk 2>/dev/null || echo "  (нет файлов в build директории)"
    echo ""
    echo "Сначала соберите APK:"
    echo "  ./build_release_apk_local.sh"
    exit 1
fi

APK_SIZE=$(du -h "$APK" | cut -f1)
print_success "APK найден: $APK ($APK_SIZE)"
echo ""

# 3. Установка
print_info "[3/5] Установка APK на устройство..."

# Деинсталляция предыдущей версии (если нужно)
print_info "Деинсталляция предыдущей версии (если установлена)..."
adb -s "$DEVICE" uninstall "$PACKAGE_NAME" > /dev/null 2>&1 || true

# Установка нового APK
if adb -s "$DEVICE" install -r "$APK"; then
    print_success "APK установлен"
else
    print_error "Не удалось установить APK"
    exit 1
fi
echo ""

# 4. Настройка логирования
print_info "[4/5] Настройка логирования..."
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/xray_test_$(date +%Y%m%d_%H%M%S).log"

# Останавливаем старые процессы logcat
pkill -f "adb.*logcat.*$PACKAGE_NAME" 2>/dev/null || true

# Очищаем старые логи
adb -s "$DEVICE" logcat -c > /dev/null 2>&1

# Запускаем logcat в фоне для XRay протоколов
(
    adb -s "$DEVICE" logcat | grep --line-buffered -E "($PACKAGE_NAME|GraniVpnService|SingBoxWrapper|Xray|VpnService)" | tee "$LOG_FILE" > /dev/null &
    echo $! > "$LOG_DIR/logcat.pid"
) &

sleep 1
print_success "Логи сохраняются в: $LOG_FILE"
print_info "Для просмотра логов в реальном времени: tail -f $LOG_FILE"
echo ""

# 5. Запуск приложения
print_info "[5/5] Запуск приложения..."
adb -s "$DEVICE" shell am force-stop "$PACKAGE_NAME" > /dev/null 2>&1 || true
sleep 0.5

if adb -s "$DEVICE" shell am start -n "$PACKAGE_NAME/.MainActivity" > /dev/null 2>&1; then
    print_success "Приложение запущено"
else
    print_warning "Не удалось запустить приложение автоматически, попробуйте запустить вручную"
fi
echo ""

echo "=========================================="
echo "  ✅ ГОТОВО!"
echo "=========================================="
echo ""
echo "Устройство: $DEVICE ($DEVICE_MODEL)"
echo "Приложение: $PACKAGE_NAME"
echo "APK: $APK"
echo "Логи: $LOG_FILE"
echo ""
echo "Для просмотра логов XRay протоколов:"
echo "  tail -f $LOG_FILE"
echo ""
echo "Для остановки логирования:"
echo "  pkill -f 'adb.*logcat.*$PACKAGE_NAME'"
echo ""

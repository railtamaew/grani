#!/bin/bash
# Скрипт для локальной сборки release APK для тестирования
# Используется до активации upload key в Google Play (16 января 2026)

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
export JAVA_HOME=/usr/lib/jvm/java-1.17.0-openjdk-amd64
export ANDROID_HOME=/opt/android-sdk
export ANDROID_SDK_ROOT=/opt/android-sdk
export PATH=$PATH:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools

PROJECT_DIR="/opt/grani"
MOBILE_APP_DIR="$PROJECT_DIR/mobile-app"
LOG_FILE="/tmp/release_apk_local_build_$(date +%Y%m%d_%H%M%S).log"

cd "$MOBILE_APP_DIR"

echo "=========================================="
echo "  Локальная сборка RELEASE APK"
echo "=========================================="
echo ""

# Проверка keystore
print_info "Проверка конфигурации подписи..."
KEYSTORE_FILE="$MOBILE_APP_DIR/android/granivpn-release-key.jks"
KEY_PROPERTIES="$MOBILE_APP_DIR/android/key.properties"

if [ ! -f "$KEYSTORE_FILE" ]; then
    print_error "Keystore не найден: $KEYSTORE_FILE"
    exit 1
fi

if [ ! -f "$KEY_PROPERTIES" ]; then
    print_error "key.properties не найден: $KEY_PROPERTIES"
    exit 1
fi

print_success "Keystore и конфигурация найдены"

# Получение версии из local.properties
VERSION_NAME=$(grep "flutter.versionName" "$MOBILE_APP_DIR/android/local.properties" | cut -d'=' -f2 | tr -d ' ')
VERSION_CODE=$(grep "flutter.versionCode" "$MOBILE_APP_DIR/android/local.properties" | cut -d'=' -f2 | tr -d ' ')

if [ -z "$VERSION_NAME" ] || [ -z "$VERSION_CODE" ]; then
    print_warning "Не удалось получить версию из local.properties, используем значения по умолчанию"
    VERSION_NAME="1.0.2"
    VERSION_CODE="8"
fi

print_info "Версия: $VERSION_NAME+$VERSION_CODE"

# Очистка предыдущей сборки
print_info "Очистка предыдущей сборки..."
/opt/flutter/bin/flutter clean > /dev/null 2>&1 || true

# Получение зависимостей
print_info "Получение зависимостей..."
/opt/flutter/bin/flutter pub get >> "$LOG_FILE" 2>&1

# Сборка RELEASE APK
print_info "Сборка RELEASE APK (это может занять 5-10 минут)..."
if /opt/flutter/bin/flutter build apk --release >> "$LOG_FILE" 2>&1; then
    print_success "Сборка завершена"
else
    print_error "Ошибка сборки. Лог: $LOG_FILE"
    echo "Последние 50 строк лога:"
    tail -50 "$LOG_FILE"
    exit 1
fi

# Проверка результата
APK_PATH="$MOBILE_APP_DIR/build/app/outputs/flutter-apk/app-release.apk"
if [ ! -f "$APK_PATH" ]; then
    print_error "APK файл не найден: $APK_PATH"
    exit 1
fi

# Копирование с версионированием
OUTPUT_DIR="$PROJECT_DIR/release_apks"
mkdir -p "$OUTPUT_DIR"
OUTPUT_APK="$OUTPUT_DIR/app-release-v${VERSION_NAME}+${VERSION_CODE}.apk"

cp "$APK_PATH" "$OUTPUT_APK"

APK_SIZE=$(du -h "$OUTPUT_APK" | cut -f1)
print_success "APK собран: $OUTPUT_APK ($APK_SIZE)"

# Проверка подписи
print_info "Проверка подписи APK..."
if keytool -printcert -jarfile "$OUTPUT_APK" > /dev/null 2>&1; then
    SHA1=$(keytool -printcert -jarfile "$OUTPUT_APK" 2>/dev/null | grep "SHA1:" | awk '{print $2}')
    print_success "APK подписан (SHA1: $SHA1)"
else
    print_warning "Не удалось проверить подпись APK"
fi

echo ""
echo "=========================================="
echo "  ✅ ГОТОВО!"
echo "=========================================="
echo ""
echo "APK файл: $OUTPUT_APK"
echo "Размер: $APK_SIZE"
echo "Версия: $VERSION_NAME+$VERSION_CODE"
echo ""
echo "Для установки на устройство используйте:"
echo "  ./install_release_apk.sh"
echo ""

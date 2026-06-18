#!/bin/bash
# Скрипт для синхронизации проекта, сборки APK на сервере и скачивания
# Использование: ./build-and-deploy-apk.sh

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Настройки
SERVER_IP="159.223.199.122"
SERVER_USER="root"
SERVER_PATH="/opt/grani"
LOCAL_PATH="$(cd "$(dirname "$0")/.." && pwd)"
MOBILE_APP_PATH="${SERVER_PATH}/mobile-app"
APK_REMOTE_PATH="${MOBILE_APP_PATH}/build/app/outputs/flutter-apk/app-debug.apk"
APK_LOCAL_PATH="${LOCAL_PATH}/mobile-app/app-debug.apk"

print_status "🚀 Сборка APK на сервере..."

# 1. Синхронизация проекта
print_status "[1/3] Синхронизация проекта с сервером..."
if [ -f "${LOCAL_PATH}/server-config/sync-to-server.sh" ]; then
    bash "${LOCAL_PATH}/server-config/sync-to-server.sh"
else
    print_warning "Скрипт sync-to-server.sh не найден, пропускаем синхронизацию"
fi

# 2. Сборка APK на сервере
print_status "[2/3] Сборка APK на сервере..."
ssh -o StrictHostKeyChecking=no ${SERVER_USER}@${SERVER_IP} << 'ENDSSH'
    set -e
    
    # Цвета
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
    
    print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
    print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
    print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
    
    PROJECT_PATH="/opt/grani"
    MOBILE_APP_PATH="${PROJECT_PATH}/mobile-app"
    
    if [ ! -d "${MOBILE_APP_PATH}" ]; then
        print_error "Проект не найден в ${MOBILE_APP_PATH}"
        exit 1
    fi
    
    cd "${MOBILE_APP_PATH}"
    
    # Проверка Flutter
    if ! command -v flutter &> /dev/null; then
        if [ -d "${MOBILE_APP_PATH}/flutter" ]; then
            export PATH="${MOBILE_APP_PATH}/flutter/bin:${PATH}"
        else
            print_error "Flutter не установлен!"
            exit 1
        fi
    fi
    
    # Проверка Android SDK
    if [ -z "$ANDROID_HOME" ] && [ -z "$ANDROID_SDK_ROOT" ]; then
        if [ -d "$HOME/Android/Sdk" ]; then
            export ANDROID_HOME="$HOME/Android/Sdk"
            export ANDROID_SDK_ROOT="$HOME/Android/Sdk"
        elif [ -d "/opt/android-sdk" ]; then
            export ANDROID_HOME="/opt/android-sdk"
            export ANDROID_SDK_ROOT="/opt/android-sdk"
        else
            print_error "Android SDK не найден!"
            exit 1
        fi
    fi
    
    print_status "Очистка проекта..."
    flutter clean
    
    print_status "Получение зависимостей..."
    flutter pub get
    
    print_status "Сборка APK..."
    flutter build apk --debug
    
    APK_FILE="${MOBILE_APP_PATH}/build/app/outputs/flutter-apk/app-debug.apk"
    if [ -f "${APK_FILE}" ]; then
        APK_SIZE=$(du -h "${APK_FILE}" | cut -f1)
        print_success "✅ APK собран: ${APK_FILE} (${APK_SIZE})"
    else
        print_error "APK файл не найден!"
        exit 1
    fi
ENDSSH

if [ $? -ne 0 ]; then
    print_error "Ошибка при сборке APK на сервере"
    exit 1
fi

# 3. Скачивание APK
print_status "[3/3] Скачивание APK с сервера..."
scp -o StrictHostKeyChecking=no ${SERVER_USER}@${SERVER_IP}:${APK_REMOTE_PATH} "${APK_LOCAL_PATH}"

if [ $? -eq 0 ]; then
    APK_SIZE=$(du -h "${APK_LOCAL_PATH}" | cut -f1)
    print_success "✅ APK скачан: ${APK_LOCAL_PATH} (${APK_SIZE})"
    print_status ""
    print_status "📱 APK готов к установке!"
    print_status "   Файл: ${APK_LOCAL_PATH}"
else
    print_error "Ошибка при скачивании APK"
    exit 1
fi

print_success "✅ Готово! APK собран и скачан"



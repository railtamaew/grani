#!/bin/bash
# Скрипт для сборки APK на сервере
# Использование: ssh root@SERVER_IP 'bash -s' < build-apk-on-server.sh
# Или: ./build-apk-on-server.sh (если запускается на сервере)

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
PROJECT_PATH="/opt/grani"
MOBILE_APP_PATH="${PROJECT_PATH}/mobile-app"
APK_OUTPUT_PATH="${MOBILE_APP_PATH}/build/app/outputs/flutter-apk"

print_status "🔨 Сборка APK на сервере..."

# Проверка наличия проекта
if [ ! -d "${MOBILE_APP_PATH}" ]; then
    print_error "Проект не найден в ${MOBILE_APP_PATH}"
    exit 1
fi

cd "${MOBILE_APP_PATH}"

# 1. Проверка Flutter
print_status "[1/6] Проверка Flutter SDK..."
if ! command -v flutter &> /dev/null; then
    print_warning "Flutter не найден в PATH, проверяем локальную установку..."
    
    # Проверка локальной установки Flutter
    if [ -d "${MOBILE_APP_PATH}/flutter" ]; then
        export PATH="${MOBILE_APP_PATH}/flutter/bin:${PATH}"
        print_success "Используется локальный Flutter"
    else
        print_error "Flutter не установлен!"
        print_warning "Установите Flutter:"
        print_warning "  cd /opt"
        print_warning "  git clone https://github.com/flutter/flutter.git -b stable"
        print_warning "  export PATH=\"/opt/flutter/bin:\$PATH\""
        exit 1
    fi
fi

FLUTTER_VERSION=$(flutter --version | head -n 1)
print_success "Flutter найден: ${FLUTTER_VERSION}"

# 2. Проверка Android SDK
print_status "[2/6] Проверка Android SDK..."
if [ -z "$ANDROID_HOME" ] && [ -z "$ANDROID_SDK_ROOT" ]; then
    print_warning "ANDROID_HOME не установлен, проверяем стандартные пути..."
    
    # Проверка стандартных путей
    if [ -d "$HOME/Android/Sdk" ]; then
        export ANDROID_HOME="$HOME/Android/Sdk"
        export ANDROID_SDK_ROOT="$HOME/Android/Sdk"
        print_success "Android SDK найден: $ANDROID_HOME"
    elif [ -d "/opt/android-sdk" ]; then
        export ANDROID_HOME="/opt/android-sdk"
        export ANDROID_SDK_ROOT="/opt/android-sdk"
        print_success "Android SDK найден: $ANDROID_HOME"
    else
        print_error "Android SDK не найден!"
        print_warning "Установите Android SDK или установите переменную ANDROID_HOME"
        exit 1
    fi
else
    print_success "Android SDK: ${ANDROID_HOME:-$ANDROID_SDK_ROOT}"
fi

# 3. Принятие лицензий Android
print_status "[3/6] Принятие лицензий Android..."
yes | flutter doctor --android-licenses 2>/dev/null || print_warning "Не удалось принять лицензии (возможно уже приняты)"

# 4. Очистка проекта
print_status "[4/6] Очистка проекта..."
flutter clean
print_success "Проект очищен"

# 5. Получение зависимостей
print_status "[5/6] Получение зависимостей..."
flutter pub get
if [ $? -ne 0 ]; then
    print_error "Ошибка при получении зависимостей"
    exit 1
fi
print_success "Зависимости получены"

# 6. Сборка APK
print_status "[6/6] Сборка debug APK..."
flutter build apk --debug
if [ $? -ne 0 ]; then
    print_error "Ошибка при сборке APK"
    exit 1
fi

# Проверка результата
APK_FILE="${APK_OUTPUT_PATH}/app-debug.apk"
if [ -f "${APK_FILE}" ]; then
    APK_SIZE=$(du -h "${APK_FILE}" | cut -f1)
    print_success "✅ APK успешно собран!"
    print_success "Файл: ${APK_FILE}"
    print_success "Размер: ${APK_SIZE}"
    
    # Информация для скачивания
    print_status ""
    print_status "📥 Для скачивания APK:"
    print_status "  scp root@159.223.199.122:${APK_FILE} ./app-debug.apk"
    print_status ""
    print_status "Или через веб-сервер (если настроен):"
    print_status "  wget http://159.223.199.122:8080/app-debug.apk"
else
    print_error "APK файл не найден после сборки!"
    exit 1
fi

print_success "✅ Сборка завершена успешно!"



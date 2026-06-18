#!/bin/bash
# Скрипт для скачивания, установки и запуска APK
# Последнее обновление: $(date +%Y-%m-%d)
set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Конфигурация
ANDROID_HOME=${ANDROID_HOME:-/opt/android-sdk}
ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-/opt/android-sdk}
JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-1.17.0-openjdk-amd64}
FLUTTER_HOME=${FLUTTER_HOME:-/opt/flutter}
PROJECT_DIR="/opt/grani"
MOBILE_APP_DIR="$PROJECT_DIR/mobile-app"
APK_PATH="$MOBILE_APP_DIR/build/app/outputs/flutter-apk/app-debug.apk"
PACKAGE_NAME="com.granivpn.mobile.debug"
LOG_DIR="$PROJECT_DIR/logs"
LOG_FILE="$LOG_DIR/app_$(date +%Y%m%d_%H%M%S).log"

# Добавляем пути к ADB
export PATH=$PATH:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin
export ANDROID_HOME
export ANDROID_SDK_ROOT
export JAVA_HOME

# Функции
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

# Проверка наличия ADB
check_adb() {
    if ! command -v adb &> /dev/null; then
        print_error "ADB не найден. Убедитесь, что Android SDK установлен и добавлен в PATH"
        exit 1
    fi
    print_success "ADB найден: $(which adb)"
}

# Проверка подключенных устройств
check_devices() {
    print_info "Проверка подключенных устройств..."
    
    # Запускаем adb server если не запущен
    adb start-server > /dev/null 2>&1
    
    DEVICES=$(adb devices | grep -v "List" | grep "device$" | awk '{print $1}')
    
    if [ -z "$DEVICES" ]; then
        print_error "Не найдено подключенных устройств или эмуляторов"
        print_info "Доступные устройства:"
        adb devices
        print_info "\nДля запуска эмулятора используйте:"
        print_info "  emulator -avd <имя_avd>"
        print_info "\nИли подключите физическое устройство через USB и включите отладку по USB"
        exit 1
    fi
    
    DEVICE_COUNT=$(echo "$DEVICES" | wc -l)
    print_success "Найдено устройств: $DEVICE_COUNT"
    
    # Если несколько устройств, используем первое
    if [ $DEVICE_COUNT -gt 1 ]; then
        print_warning "Найдено несколько устройств. Используется первое:"
        FIRST_DEVICE=$(echo "$DEVICES" | head -n1)
        print_info "  $FIRST_DEVICE"
    fi
    
    SELECTED_DEVICE=$(echo "$DEVICES" | head -n1)
    print_info "Используемое устройство: $SELECTED_DEVICE"
    
    # Получаем информацию об устройстве
    DEVICE_INFO=$(adb -s "$SELECTED_DEVICE" shell getprop ro.product.model 2>/dev/null || echo "Unknown")
    print_info "Модель устройства: $DEVICE_INFO"
}

# Поиск или сборка APK
get_apk() {
    print_info "Поиск APK файла..."
    
    if [ -f "$APK_PATH" ]; then
        print_success "APK найден: $APK_PATH"
        APK_SIZE=$(du -h "$APK_PATH" | cut -f1)
        print_info "Размер: $APK_SIZE"
        return 0
    fi
    
    print_warning "APK не найден. Попытка сборки..."
    
    if [ ! -d "$MOBILE_APP_DIR" ]; then
        print_error "Директория мобильного приложения не найдена: $MOBILE_APP_DIR"
        exit 1
    fi
    
    # Проверяем наличие Flutter
    if [ ! -f "$FLUTTER_HOME/bin/flutter" ]; then
        print_error "Flutter не найден: $FLUTTER_HOME/bin/flutter"
        exit 1
    fi
    
    print_info "Запуск сборки APK..."
    cd "$MOBILE_APP_DIR"
    
    # Получаем зависимости
    print_info "Получение зависимостей..."
    "$FLUTTER_HOME/bin/flutter" pub get
    
    # Собираем APK
    print_info "Сборка APK (это может занять несколько минут)..."
    "$FLUTTER_HOME/bin/flutter" build apk --debug
    
    if [ -f "$APK_PATH" ]; then
        print_success "APK успешно собран: $APK_PATH"
        APK_SIZE=$(du -h "$APK_PATH" | cut -f1)
        print_info "Размер: $APK_SIZE"
    else
        print_error "Не удалось собрать APK"
        exit 1
    fi
}

# Установка APK
install_apk() {
    print_info "Установка APK на устройство..."
    
    # Удаляем старое приложение если установлено
    print_info "Проверка существующей установки..."
    if adb -s "$SELECTED_DEVICE" shell pm list packages | grep -q "$PACKAGE_NAME"; then
        print_warning "Приложение уже установлено. Удаление старой версии..."
        adb -s "$SELECTED_DEVICE" uninstall "$PACKAGE_NAME" > /dev/null 2>&1 || true
    fi
    
    # Устанавливаем APK
    print_info "Установка новой версии..."
    if adb -s "$SELECTED_DEVICE" install -r "$APK_PATH"; then
        print_success "APK успешно установлен"
    else
        print_error "Ошибка установки APK"
        exit 1
    fi
}

# Настройка логирования
setup_logging() {
    print_info "Настройка логирования..."
    
    # Создаем директорию для логов
    mkdir -p "$LOG_DIR"
    
    # Очищаем старые логи (опционально)
    print_info "Логи будут сохраняться в: $LOG_FILE"
    
    # Запускаем logcat в фоне
    print_info "Запуск logcat в фоне..."
    
    # Останавливаем предыдущие процессы logcat для этого пакета
    pkill -f "adb.*logcat.*$PACKAGE_NAME" 2>/dev/null || true
    
    # Запускаем logcat с фильтрацией по пакету
    (
        adb -s "$SELECTED_DEVICE" logcat -c  # Очищаем старые логи
        adb -s "$SELECTED_DEVICE" logcat | grep --line-buffered -E "($PACKAGE_NAME|flutter|AndroidRuntime)" | tee "$LOG_FILE" &
        LOGCAT_PID=$!
        echo $LOGCAT_PID > "$LOG_DIR/logcat.pid"
    ) &
    
    sleep 2
    print_success "Логирование запущено (PID сохранен в $LOG_DIR/logcat.pid)"
    print_info "Просмотр логов в реальном времени: tail -f $LOG_FILE"
}

# Запуск приложения
launch_app() {
    print_info "Запуск приложения..."
    
    # Останавливаем приложение если запущено
    adb -s "$SELECTED_DEVICE" shell am force-stop "$PACKAGE_NAME" > /dev/null 2>&1 || true
    
    # Запускаем главную активность
    adb -s "$SELECTED_DEVICE" shell monkey -p "$PACKAGE_NAME" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
    
    sleep 1
    
    # Альтернативный способ запуска через am start
    adb -s "$SELECTED_DEVICE" shell am start -n "$PACKAGE_NAME/.MainActivity" > /dev/null 2>&1
    
    print_success "Приложение запущено"
    print_info "Пакет: $PACKAGE_NAME"
}

# Остановка логирования
stop_logging() {
    if [ -f "$LOG_DIR/logcat.pid" ]; then
        LOGCAT_PID=$(cat "$LOG_DIR/logcat.pid")
        if ps -p "$LOGCAT_PID" > /dev/null 2>&1; then
            kill "$LOGCAT_PID" 2>/dev/null || true
            print_info "Логирование остановлено"
        fi
        rm -f "$LOG_DIR/logcat.pid"
    fi
    # Останавливаем все процессы logcat
    pkill -f "adb.*logcat" 2>/dev/null || true
}

# Обработка сигналов для корректного завершения
trap stop_logging EXIT INT TERM

# Главная функция
main() {
    echo "=========================================="
    echo "  Установка и запуск Android приложения"
    echo "=========================================="
    echo ""
    
    # Парсинг аргументов
    SKIP_BUILD=false
    SKIP_INSTALL=false
    SKIP_LAUNCH=false
    NO_LOGS=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --skip-install)
                SKIP_INSTALL=true
                shift
                ;;
            --skip-launch)
                SKIP_LAUNCH=true
                shift
                ;;
            --no-logs)
                NO_LOGS=true
                shift
                ;;
            --help|-h)
                echo "Использование: $0 [опции]"
                echo ""
                echo "Опции:"
                echo "  --skip-build    Пропустить сборку APK (использовать существующий)"
                echo "  --skip-install  Пропустить установку (только запуск)"
                echo "  --skip-launch   Пропустить запуск приложения"
                echo "  --no-logs       Не запускать логирование"
                echo "  --help, -h      Показать эту справку"
                echo ""
                exit 0
                ;;
            *)
                print_error "Неизвестная опция: $1"
                echo "Используйте --help для справки"
                exit 1
                ;;
        esac
    done
    
    # Выполнение шагов
    check_adb
    check_devices
    
    if [ "$SKIP_BUILD" = false ]; then
        get_apk
    else
        if [ ! -f "$APK_PATH" ]; then
            print_error "APK не найден: $APK_PATH"
            exit 1
        fi
        print_info "Пропущена сборка, используется существующий APK"
    fi
    
    if [ "$SKIP_INSTALL" = false ]; then
        install_apk
    else
        print_info "Пропущена установка"
    fi
    
    if [ "$NO_LOGS" = false ]; then
        setup_logging
    else
        print_info "Логирование отключено"
    fi
    
    if [ "$SKIP_LAUNCH" = false ]; then
        launch_app
    else
        print_info "Пропущен запуск приложения"
    fi
    
    echo ""
    echo "=========================================="
    print_success "Готово!"
    echo "=========================================="
    echo ""
    print_info "Полезные команды:"
    echo "  Просмотр логов:     tail -f $LOG_FILE"
    echo "  Остановка приложения: adb -s $SELECTED_DEVICE shell am force-stop $PACKAGE_NAME"
    echo "  Перезапуск:         $0 --skip-build"
    echo "  Просмотр всех логов: adb -s $SELECTED_DEVICE logcat"
    echo ""
    
    if [ "$NO_LOGS" = false ]; then
        print_info "Логирование работает в фоне. Для остановки нажмите Ctrl+C"
        # Ждем сигнала завершения
        wait
    fi
}

# Запуск
main "$@"







#!/bin/bash

# Скрипт для полного прогона AndroidTest с параметрами
# Использование: ./scripts/run_all_tests.sh [--singbox-config FILE] [--wireguard-config FILE]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

SINGBOX_CONFIG=""
WIREGUARD_CONFIG=""
SINGBOX_B64=""
WIREGUARD_B64=""

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
    case $1 in
        --singbox-config)
            SINGBOX_CONFIG="$2"
            shift 2
            ;;
        --wireguard-config)
            WIREGUARD_CONFIG="$2"
            shift 2
            ;;
        --singbox-b64)
            SINGBOX_B64="$2"
            shift 2
            ;;
        --wireguard-b64)
            WIREGUARD_B64="$2"
            shift 2
            ;;
        *)
            echo "❌ Неизвестный параметр: $1"
            echo ""
            echo "Использование:"
            echo "  $0 [--singbox-config FILE] [--wireguard-config FILE]"
            echo "  $0 [--singbox-b64 BASE64] [--wireguard-b64 BASE64]"
            exit 1
            ;;
    esac
done

echo "🧪 Полный прогон AndroidTest..."
echo ""

# Проверка подключения устройства
if ! adb devices | grep -q "device$"; then
    echo "❌ Ошибка: Устройство не подключено"
    exit 1
fi

# Проверка установки приложения
if ! adb shell pm list packages | grep -q "com.granivpn.mobile"; then
    echo "⚠️  Приложение не установлено, устанавливаю..."
    "$SCRIPT_DIR/install_apk.sh"
fi

# Подготовка конфигураций
GRADLE_ARGS=""

if [ -n "$SINGBOX_CONFIG" ]; then
    if [ ! -f "$SINGBOX_CONFIG" ]; then
        echo "❌ Ошибка: Файл sing-box конфигурации не найден: $SINGBOX_CONFIG"
        exit 1
    fi
    SINGBOX_B64=$(base64 -w 0 < "$SINGBOX_CONFIG")
    echo "✅ Sing-box конфигурация загружена из файла"
fi

if [ -n "$WIREGUARD_CONFIG" ]; then
    if [ ! -f "$WIREGUARD_CONFIG" ]; then
        echo "❌ Ошибка: Файл WireGuard конфигурации не найден: $WIREGUARD_CONFIG"
        exit 1
    fi
    WIREGUARD_B64=$(base64 -w 0 < "$WIREGUARD_CONFIG")
    echo "✅ WireGuard конфигурация загружена из файла"
fi

# Формирование аргументов Gradle
if [ -n "$SINGBOX_B64" ]; then
    GRADLE_ARGS="$GRADLE_ARGS -Pandroid.testInstrumentationRunnerArguments.singbox_config_b64=$SINGBOX_B64"
fi

if [ -n "$WIREGUARD_B64" ]; then
    GRADLE_ARGS="$GRADLE_ARGS -Pandroid.testInstrumentationRunnerArguments.wireguard_config_b64=$WIREGUARD_B64"
fi

echo ""
echo "▶️  Запуск connectedDebugAndroidTest..."
echo ""

# Запуск тестов через Gradle
./gradlew :app:connectedDebugAndroidTest $GRADLE_ARGS

TEST_RESULT=$?

if [ $TEST_RESULT -eq 0 ]; then
    echo ""
    echo "✅ Все тесты завершены успешно!"
    echo ""
    echo "📊 Отчеты доступны в:"
    echo "   - HTML: app/build/app/reports/androidTests/connected/debug/index.html"
    echo "   - XML: app/build/app/outputs/androidTest-results/connected/debug/"
else
    echo ""
    echo "❌ Тесты завершены с ошибками (код: $TEST_RESULT)"
    echo ""
    echo "📊 Проверьте отчеты в:"
    echo "   - HTML: app/build/app/reports/androidTests/connected/debug/index.html"
    exit $TEST_RESULT
fi

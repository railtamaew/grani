#!/bin/bash

# Скрипт для запуска sing-box теста с конфигурацией
# Использование: ./scripts/run_singbox_test.sh [config_file|config_b64]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# Параметры
CONFIG_ARG=""
CONFIG_B64=""

if [ -z "$1" ]; then
    echo "❌ Ошибка: Не указана конфигурация"
    echo ""
    echo "Использование:"
    echo "  $0 <config_file>              # Путь к файлу с конфигурацией"
    echo "  $0 --b64 <base64_config>       # Base64-encoded конфигурация"
    echo ""
    echo "Пример:"
    echo "  $0 /path/to/singbox-config.json"
    echo "  $0 --b64 eyJsb2c... (base64 строка)"
    exit 1
fi

# Обработка аргументов
if [ "$1" == "--b64" ]; then
    if [ -z "$2" ]; then
        echo "❌ Ошибка: Не указана base64 конфигурация"
        exit 1
    fi
    CONFIG_B64="$2"
else
    CONFIG_FILE="$1"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "❌ Ошибка: Файл конфигурации не найден: $CONFIG_FILE"
        exit 1
    fi
    # Кодируем в base64
    CONFIG_B64=$(base64 -w 0 < "$CONFIG_FILE")
fi

echo "🧪 Запуск sing-box теста..."
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

echo "📋 Конфигурация (первые 100 символов): ${CONFIG_B64:0:100}..."
echo ""

# Запуск теста
echo "▶️  Запуск теста start_singbox_with_provided_config..."
adb shell am instrument -w \
    -e singbox_config_b64 "$CONFIG_B64" \
    -e class com.granivpn.mobile.VpnServiceIntegrationTest#start_singbox_with_provided_config \
    com.granivpn.mobile.test/androidx.test.runner.AndroidJUnitRunner

TEST_RESULT=$?

if [ $TEST_RESULT -eq 0 ]; then
    echo ""
    echo "✅ Тест завершен успешно!"
else
    echo ""
    echo "❌ Тест завершен с ошибкой (код: $TEST_RESULT)"
    exit $TEST_RESULT
fi

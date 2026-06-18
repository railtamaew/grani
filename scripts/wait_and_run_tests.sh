#!/bin/bash

# Скрипт ожидания подключения устройства и запуска тестов
# Использование: /opt/grani/scripts/wait_and_run_tests.sh [--timeout SECONDS]

set -euo pipefail

TIMEOUT=300  # По умолчанию 5 минут

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
    case $1 in
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        *)
            echo "❌ Неизвестный параметр: $1"
            exit 1
            ;;
    esac
done

PROJECT_DIR="/opt/grani/mobile-app/android"
SINGBOX_CONFIG="${PROJECT_DIR}/test_configs/singbox_reality_valid.json"
WIREGUARD_CONFIG="${PROJECT_DIR}/test_configs/wireguard_valid.conf"

echo "=========================================="
echo "  Ожидание подключения устройства"
echo "=========================================="
echo ""
echo "Таймаут: $TIMEOUT секунд"
echo ""

# Ожидание подключения устройства
echo "[1/4] Ожидание подключения устройства..."
START_TIME=$(date +%s)

while [ $(($(date +%s) - START_TIME)) -lt $TIMEOUT ]; do
    if adb devices | grep -q "device$"; then
        DEVICE=$(adb devices | grep "device$" | head -1 | awk '{print $1}')
        echo "   ✅ Устройство найдено: $DEVICE"
        
        # Получаем информацию об устройстве
        DEVICE_MODEL=$(adb -s "$DEVICE" shell "getprop ro.product.model" 2>/dev/null | tr -d '\r\n' || echo "Unknown")
        ANDROID_VERSION=$(adb -s "$DEVICE" shell "getprop ro.build.version.release" 2>/dev/null | tr -d '\r\n' || echo "Unknown")
        
        echo "   Модель: $DEVICE_MODEL"
        echo "   Android: $ANDROID_VERSION"
        break
    else
        ELAPSED=$(($(date +%s) - START_TIME))
        REMAINING=$((TIMEOUT - ELAPSED))
        if [ $REMAINING -gt 0 ]; then
            echo "   Ожидание... (осталось ~$REMAINING сек)"
            sleep 5
        else
            echo "   ❌ Таймаут ожидания устройства"
            echo ""
            echo "💡 Инструкции по подключению:"
            echo "   1. На вашем компьютере:"
            echo "      scp root@granilink.com:/opt/grani/scripts/setup_adb_remote_client.sh ./"
            echo "      chmod +x setup_adb_remote_client.sh"
            echo "      ./setup_adb_remote_client.sh"
            echo ""
            echo "   2. На сервере:"
            echo "      /opt/grani/scripts/connect_remote_device.sh"
            exit 1
        fi
    fi
done

if ! adb devices | grep -q "device$"; then
    echo "   ❌ Устройство не подключено"
    exit 1
fi

echo ""

# Проверка установки приложения
echo "[2/4] Проверка установки приложения..."
if ! adb shell pm list packages | grep -q "com.granivpn.mobile"; then
    echo "   ⚠️  Приложение не установлено, устанавливаю..."
    cd "$PROJECT_DIR"
    "$PROJECT_DIR/scripts/install_apk.sh"
else
    echo "   ✅ Приложение установлено"
fi
echo ""

# Проверка конфигураций
echo "[3/4] Проверка тестовых конфигураций..."
if [ ! -f "$SINGBOX_CONFIG" ]; then
    echo "   ⚠️  Sing-box конфигурация не найдена: $SINGBOX_CONFIG"
    echo "   Используется: singbox_valid.json"
    SINGBOX_CONFIG="${PROJECT_DIR}/test_configs/singbox_valid.json"
fi

if [ ! -f "$WIREGUARD_CONFIG" ]; then
    echo "   ⚠️  WireGuard конфигурация не найдена: $WIREGUARD_CONFIG"
    echo "   Используется: wireguard_valid.conf"
    WIREGUARD_CONFIG="${PROJECT_DIR}/test_configs/wireguard_valid.conf"
fi

if [ -f "$SINGBOX_CONFIG" ]; then
    echo "   ✅ Sing-box конфигурация: $(basename $SINGBOX_CONFIG)"
fi

if [ -f "$WIREGUARD_CONFIG" ]; then
    echo "   ✅ WireGuard конфигурация: $(basename $WIREGUARD_CONFIG)"
fi
echo ""

# Запуск тестов
echo "[4/4] Запуск тестов..."
cd "$PROJECT_DIR"

echo "   Запуск Android тестов..."
echo ""

"$PROJECT_DIR/scripts/run_all_tests.sh" \
    --singbox-config "$SINGBOX_CONFIG" \
    --wireguard-config "$WIREGUARD_CONFIG"

TEST_RESULT=$?

echo ""
echo "=========================================="
if [ $TEST_RESULT -eq 0 ]; then
    echo "  ✅ Тесты завершены успешно!"
else
    echo "  ❌ Тесты завершены с ошибками"
fi
echo "=========================================="
echo ""

exit $TEST_RESULT

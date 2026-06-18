#!/bin/bash

# Скрипт для подключения к удаленному устройству через SSH туннель
# Использование: /opt/grani/scripts/connect_remote_device.sh [IP:PORT] [--scan]

set -euo pipefail

ANDROID_SDK_ROOT="/opt/android-sdk"
export PATH="${PATH}:${ANDROID_SDK_ROOT}/platform-tools"

ADB_PORT=5555

echo "=========================================="
echo "  Подключение к удаленному устройству"
echo "=========================================="
echo ""

# Проверка ADB
if ! command -v adb &> /dev/null; then
    echo "❌ Ошибка: ADB не найден"
    exit 1
fi

# Режим сканирования
if [[ "${1:-}" == "--scan" ]]; then
    echo "[1/3] Сканирование сети..."
    echo "   Поиск устройств на порту $ADB_PORT..."
    
    # Получаем локальную сеть
    LOCAL_NET=$(ip route | grep default | awk '{print $3}' | cut -d. -f1-3)
    
    FOUND_DEVICES=()
    for i in {1..254}; do
        IP="${LOCAL_NET}.${i}"
        if timeout 1 adb connect "${IP}:${ADB_PORT}" 2>&1 | grep -q "connected"; then
            FOUND_DEVICES+=("${IP}:${ADB_PORT}")
            echo "   ✅ Найдено устройство: ${IP}:${ADB_PORT}"
        fi
    done
    
    if [ ${#FOUND_DEVICES[@]} -eq 0 ]; then
        echo "   ❌ Устройства не найдены"
        exit 1
    fi
    
    DEVICE="${FOUND_DEVICES[0]}"
    echo ""
    echo "   Используется: $DEVICE"
    
# Прямое подключение
elif [ -n "${1:-}" ]; then
    DEVICE="$1"
    if [[ ! "$DEVICE" =~ : ]]; then
        DEVICE="${DEVICE}:${ADB_PORT}"
    fi
else
    # Проверка через localhost (SSH туннель)
    echo "[1/3] Проверка SSH туннеля..."
    if adb connect "localhost:${ADB_PORT}" 2>&1 | grep -q "connected\|already connected"; then
        DEVICE="localhost:${ADB_PORT}"
        echo "   ✅ Устройство найдено через SSH туннель"
    else
        echo "   ❌ Устройство не найдено через SSH туннель"
        echo ""
        echo "💡 Использование:"
        echo "   $0 IP:PORT              # Прямое подключение"
        echo "   $0 --scan               # Сканирование сети"
        echo "   $0                      # Подключение через SSH туннель (localhost:5555)"
        exit 1
    fi
fi
echo ""

# Подключение
echo "[2/3] Подключение к устройству..."
if adb connect "$DEVICE" 2>&1 | grep -q "connected\|already connected"; then
    echo "   ✅ Устройство подключено: $DEVICE"
else
    echo "   ❌ Не удалось подключиться к $DEVICE"
    exit 1
fi
echo ""

# Проверка
echo "[3/3] Проверка подключения..."
sleep 1
if adb devices | grep -q "$DEVICE"; then
    DEVICE_INFO=$(adb -s "$DEVICE" shell "getprop ro.product.model" 2>/dev/null | tr -d '\r\n' || echo "Unknown")
    ANDROID_VERSION=$(adb -s "$DEVICE" shell "getprop ro.build.version.release" 2>/dev/null | tr -d '\r\n' || echo "Unknown")
    
    echo "   ✅ Устройство доступно"
    echo "   Модель: $DEVICE_INFO"
    echo "   Android: $ANDROID_VERSION"
else
    echo "   ❌ Устройство не отвечает"
    exit 1
fi
echo ""

# Итоги
echo "=========================================="
echo "  ✅ Устройство готово к использованию!"
echo "=========================================="
echo ""
echo "📱 Устройство: $DEVICE"
echo ""
echo "📝 Доступные команды:"
echo "   adb -s $DEVICE devices              # Проверка"
echo "   adb -s $DEVICE shell                # Shell"
echo "   adb -s $DEVICE logcat               # Логи"
echo ""
echo "🚀 Запуск приложения:"
echo "   /opt/grani/scripts/run_app_with_logging.sh"
echo ""
echo "📊 Мониторинг логов:"
echo "   /opt/grani/scripts/start_logcat_monitor.sh"
echo ""

#!/bin/bash
# Финальный скрипт для установки APK - запускайте через SSH

set -e

echo "=========================================="
echo "  Установка и запуск APK на устройстве"
echo "=========================================="
echo ""

# Настройка
export PATH=$PATH:/opt/android-sdk/platform-tools:/opt/android-sdk/cmdline-tools/latest/bin
export ANDROID_HOME=/opt/android-sdk
export ANDROID_SDK_ROOT=/opt/android-sdk

cd /opt/grani

# 1. Проверка устройств
echo "[1/5] Проверка устройств..."
adb start-server
DEVICE=$(adb devices | grep -v "List" | grep "device$" | head -1 | awk '{print $1}')

if [ -z "$DEVICE" ]; then
    echo "❌ ОШИБКА: Устройство не найдено"
    echo ""
    echo "Доступные устройства:"
    adb devices
    exit 1
fi

DEVICE_MODEL=$(adb -s "$DEVICE" shell getprop ro.product.model 2>/dev/null || echo "Unknown")
echo "✅ Устройство: $DEVICE ($DEVICE_MODEL)"
echo ""

# 2. Проверка APK
echo "[2/5] Проверка APK..."
APK="/opt/grani/mobile-app/build/app/outputs/flutter-apk/app-debug.apk"

if [ ! -f "$APK" ]; then
    echo "⚠️  APK не найден, запускаю сборку (5-10 минут)..."
    cd /opt/grani/mobile-app
    /opt/flutter/bin/flutter build apk --debug
    cd /opt/grani
    
    if [ ! -f "$APK" ]; then
        echo "❌ ОШИБКА: Не удалось собрать APK"
        exit 1
    fi
fi

APK_SIZE=$(du -h "$APK" | cut -f1)
echo "✅ APK найден: $APK_SIZE"
echo ""

# 3. Установка
echo "[3/5] Установка APK..."
adb -s "$DEVICE" uninstall com.granivpn.mobile.debug > /dev/null 2>&1 || true

if adb -s "$DEVICE" install -r "$APK"; then
    echo "✅ APK установлен"
else
    echo "❌ ОШИБКА: Не удалось установить"
    exit 1
fi
echo ""

# 4. Логирование
echo "[4/5] Настройка логирования..."
LOG_DIR="/opt/grani/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/app_$(date +%Y%m%d_%H%M%S).log"

pkill -f "adb.*logcat.*com.granivpn.mobile.debug" 2>/dev/null || true

(
    adb -s "$DEVICE" logcat -c > /dev/null 2>&1
    adb -s "$DEVICE" logcat | grep --line-buffered -E "(com.granivpn.mobile.debug|flutter|AndroidRuntime)" | tee "$LOG_FILE" > /dev/null &
    echo $! > "$LOG_DIR/logcat.pid"
) &

sleep 1
echo "✅ Логи: $LOG_FILE"
echo ""

# 5. Запуск
echo "[5/5] Запуск приложения..."
adb -s "$DEVICE" shell am force-stop com.granivpn.mobile.debug > /dev/null 2>&1 || true
sleep 0.5

adb -s "$DEVICE" shell am start -n com.granivpn.mobile.debug/.MainActivity > /dev/null 2>&1 || \
adb -s "$DEVICE" shell monkey -p com.granivpn.mobile.debug -c android.intent.category.LAUNCHER 1

echo "✅ Приложение запущено"
echo ""

echo "=========================================="
echo "  ✅ ГОТОВО!"
echo "=========================================="
echo ""
echo "Устройство: $DEVICE ($DEVICE_MODEL)"
echo "Приложение запущено: com.granivpn.mobile.debug"
echo "Логи: tail -f $LOG_FILE"
echo ""







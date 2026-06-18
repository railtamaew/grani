#!/bin/bash

# Скрипт для установки APK на подключенное устройство
# Использование: ./scripts/install_apk.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

echo "📱 Установка APK на устройство..."
echo ""

# Проверка подключения устройства
if ! adb devices | grep -q "device$"; then
    echo "❌ Ошибка: Устройство не подключено или не авторизовано"
    echo "   Убедитесь, что:"
    echo "   1. Устройство подключено по USB"
    echo "   2. Включена отладка по USB"
    echo "   3. Разрешен доступ к устройству (adb devices)"
    exit 1
fi

DEVICE=$(adb devices | grep "device$" | head -1 | cut -f1)
echo "✅ Устройство найдено: $DEVICE"
echo ""

# Установка основного APK
echo "📦 Установка основного приложения (app-debug.apk)..."
if [ -f "app/build/outputs/apk/debug/app-debug.apk" ]; then
    adb install -r app/build/outputs/apk/debug/app-debug.apk
    echo "✅ Основное приложение установлено"
else
    echo "⚠️  APK не найден, собираю..."
    ./gradlew :app:assembleDebug
    adb install -r app/build/outputs/apk/debug/app-debug.apk
    echo "✅ Основное приложение собрано и установлено"
fi
echo ""

# Установка тестового APK
echo "🧪 Установка тестового приложения (app-debug-androidTest.apk)..."
if [ -f "app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk" ]; then
    adb install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
    echo "✅ Тестовое приложение установлено"
else
    echo "⚠️  Тестовый APK не найден, собираю..."
    ./gradlew :app:assembleDebugAndroidTest
    adb install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
    echo "✅ Тестовое приложение собрано и установлено"
fi
echo ""

echo "✅ Установка завершена!"
echo ""
echo "⚠️  ВАЖНО: Выдайте VPN разрешение вручную на устройстве:"
echo "   1. Запустите приложение на устройстве"
echo "   2. При первом запросе VPN разрешения подтвердите его"
echo "   3. Или используйте: adb shell pm grant com.granivpn.mobile android.permission.BIND_VPN_SERVICE"
echo ""

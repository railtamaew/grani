#!/bin/bash

# Скрипт для сборки и установки минимального VPN приложения
# Использование: ./scripts/build_and_install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

echo "📦 Сборка минимального VPN приложения..."
echo ""

# Проверка подключения устройства
if ! adb devices | grep -q "device$"; then
    echo "❌ Ошибка: Устройство не подключено"
    echo "   Убедитесь, что устройство подключено и авторизовано (adb devices)"
    exit 1
fi

DEVICE=$(adb devices | grep "device$" | head -1 | cut -f1)
echo "✅ Устройство найдено: $DEVICE"
echo ""

# Сборка APK
echo "🔨 Сборка APK..."
flutter build apk --debug

if [ ! -f "build/app/outputs/flutter-apk/app-debug.apk" ]; then
    echo "❌ Ошибка: APK не собран"
    exit 1
fi

echo "✅ APK собран успешно"
echo ""

# Установка
echo "📱 Установка на устройство..."
adb install -r build/app/outputs/flutter-apk/app-debug.apk

echo ""
echo "✅ Приложение установлено!"
echo ""
echo "📝 Следующие шаги:"
echo "   1. Откройте приложение на устройстве"
echo "   2. Запустите логирование: adb logcat | grep MinimalVpn"
echo "   3. Нажмите 'Подключиться' в приложении"
echo ""

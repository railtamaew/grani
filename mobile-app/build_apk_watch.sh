#!/bin/bash
# Скрипт для сборки APK с выводом в терминал

cd /opt/grani/mobile-app

echo "============================================================"
echo "📦 СБОРКА APK - ВЫВОД В РЕАЛЬНОМ ВРЕМЕНИ"
echo "============================================================"
echo ""

# Очистка
echo "🧹 Очистка проекта..."
flutter clean

echo ""
echo "📦 Получение зависимостей..."
flutter pub get

echo ""
echo "🔨 Сборка APK (debug)..."
echo "============================================================"
flutter build apk --debug

BUILD_EXIT_CODE=$?

echo ""
echo "============================================================"
if [ $BUILD_EXIT_CODE -eq 0 ]; then
    echo "✅ СБОРКА ЗАВЕРШЕНА УСПЕШНО!"
    echo ""
    echo "📦 Собранные APK файлы:"
    ls -lh build/app/outputs/flutter-apk/*.apk 2>/dev/null | awk '{print "   " $9 " (" $5 ")"}'
else
    echo "❌ СБОРКА ЗАВЕРШИЛАСЬ С ОШИБКОЙ (код: $BUILD_EXIT_CODE)"
fi
echo "============================================================"

exit $BUILD_EXIT_CODE

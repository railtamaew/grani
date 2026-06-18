#!/bin/bash
# Скрипт для сборки APK версии v11-SINGBOX-FORMAT-FIXED с выводом в реальном времени
# Аналогично сборке granivpn-debug-dns-fixed.apk

set -e

cd /opt/grani/mobile-app

echo "============================================================"
echo "📦 СБОРКА APK v11-SINGBOX-FORMAT-FIXED"
echo "============================================================"
echo "Версия кода: 2026-01-15-v11-SINGBOX-FORMAT-FIXED"
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
    echo "============================================================"
    
    # Копируем APK в корень с именем версии
    if [ -f build/app/outputs/flutter-apk/app-debug.apk ]; then
        APK_NAME="granivpn-debug-v11-singbox-format-fixed.apk"
        cp build/app/outputs/flutter-apk/app-debug.apk /opt/grani/$APK_NAME
        
        echo ""
        echo "📦 APK скопирован:"
        ls -lh /opt/grani/$APK_NAME | awk '{print "   " $9 " (" $5 ")"}'
        echo ""
        echo "✅ Готово! APK: /opt/grani/$APK_NAME"
        echo ""
        echo "📋 Изменения в этой версии:"
        echo "   - Убран settings.vnext → используется server/server_port"
        echo "   - Убран stream_settings → используется tls и transport"
        echo "   - reality_settings → tls.reality"
        echo "   - DNS формат: объекты {\"address\": \"...\"}"
        echo "   - TUN inbound: без dns_address, inet4_route"
    else
        echo "❌ APK файл не найден в build/app/outputs/flutter-apk/app-debug.apk"
        exit 1
    fi
else
    echo "❌ СБОРКА ЗАВЕРШИЛАСЬ С ОШИБКОЙ (код: $BUILD_EXIT_CODE)"
    echo "============================================================"
    exit $BUILD_EXIT_CODE
fi

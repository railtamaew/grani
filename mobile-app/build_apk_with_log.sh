#!/bin/bash
# Скрипт для сборки APK с выводом в файл для мониторинга

cd /opt/grani/mobile-app
LOG_FILE="/tmp/flutter_build_live.log"

echo "============================================================"
echo "📦 СБОРКА APK"
echo "============================================================"
echo "Логи сохраняются в: $LOG_FILE"
echo "Для просмотра в реальном времени выполните в другом терминале:"
echo "  tail -f $LOG_FILE"
echo "============================================================"
echo ""

# Очистка лога
> "$LOG_FILE"

# Очистка проекта
echo "🧹 Очистка проекта..." | tee -a "$LOG_FILE"
flutter clean 2>&1 | tee -a "$LOG_FILE"

echo "" | tee -a "$LOG_FILE"
echo "📦 Получение зависимостей..." | tee -a "$LOG_FILE"
flutter pub get 2>&1 | tee -a "$LOG_FILE"

echo "" | tee -a "$LOG_FILE"
echo "🔨 Сборка APK (debug)..." | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"
flutter build apk --debug 2>&1 | tee -a "$LOG_FILE"

BUILD_EXIT_CODE=${PIPESTATUS[0]}

echo "" | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"
if [ $BUILD_EXIT_CODE -eq 0 ]; then
    echo "✅ СБОРКА ЗАВЕРШЕНА УСПЕШНО!" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "📦 Собранные APK файлы:" | tee -a "$LOG_FILE"
    ls -lh build/app/outputs/flutter-apk/*.apk 2>/dev/null | awk '{print "   " $9 " (" $5 ")"}' | tee -a "$LOG_FILE"
else
    echo "❌ СБОРКА ЗАВЕРШИЛАСЬ С ОШИБКОЙ (код: $BUILD_EXIT_CODE)" | tee -a "$LOG_FILE"
fi
echo "============================================================" | tee -a "$LOG_FILE"

# Показываем последние строки
echo ""
echo "Последние 20 строк лога:"
tail -20 "$LOG_FILE"

exit $BUILD_EXIT_CODE

#!/bin/bash

# Скрипт для запуска приложения с логированием
# Использование: ./scripts/run_with_logs.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

LOG_FILE="/tmp/vpn_minimal_test_$(date +%Y%m%d_%H%M%S).log"

echo "📊 Запуск логирования..."
echo "   Логи сохраняются в: $LOG_FILE"
echo ""

# Очистка старых логов
adb logcat -c

# Запуск логирования в фоне
adb logcat | grep -E "MinimalVpn|Flutter|AndroidRuntime" > "$LOG_FILE" &
LOGCAT_PID=$!

echo "✅ Логирование запущено (PID: $LOGCAT_PID)"
echo "   Для остановки: kill $LOGCAT_PID"
echo ""

# Запуск приложения
echo "🚀 Запуск приложения..."
adb shell am start -n com.granivpn.test.vpn_minimal/.MainActivity

echo ""
echo "📱 Приложение запущено на устройстве"
echo "📊 Логи сохраняются в: $LOG_FILE"
echo ""
echo "💡 Для просмотра логов в реальном времени:"
echo "   tail -f $LOG_FILE"
echo ""

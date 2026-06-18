#!/usr/bin/env bash
# Скрипт мониторинга logcat в реальном времени
# Использование: /opt/grani/scripts/start_logcat_monitor.sh

set -euo pipefail

PACKAGE_NAME="com.granivpn.mobile"
LOG_DIR="/opt/grani/logs/android"
LOG_FILE="${LOG_DIR}/logcat_$(date +%Y%m%d_%H%M%S).log"
PID_FILE="${LOG_DIR}/logcat.pid"

mkdir -p "$LOG_DIR"

echo "=========================================="
echo "  Запуск мониторинга logcat"
echo "=========================================="

# Остановка предыдущего процесса
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if ps -p $OLD_PID > /dev/null 2>&1; then
        kill $OLD_PID 2>/dev/null || true
        echo "Остановлен предыдущий процесс logcat (PID: $OLD_PID)"
    fi
    rm -f "$PID_FILE"
fi

# Ожидание устройства (таймаут 10 секунд)
echo "[1/3] Ожидание устройства..."
if ! timeout 10 adb wait-for-device 2>/dev/null; then
    echo "❌ Таймаут ожидания устройства"
    exit 1
fi
DEVICE=$(adb devices | grep -v "List" | grep "device" | awk '{print $1}' | head -1)

if [ -z "$DEVICE" ]; then
    echo "❌ Устройство не найдено"
    exit 1
fi

echo "   ✅ Устройство: $DEVICE"

# Очистка старых логов
echo ""
echo "[2/3] Очистка старых логов..."
adb -s "$DEVICE" logcat -c

# Запуск logcat с фильтрацией
echo ""
echo "[3/3] Запуск logcat с фильтрацией..."
adb -s "$DEVICE" logcat \
  | grep --line-buffered -E "($PACKAGE_NAME|GraniVpnService|VpnPlugin|VpnService|SingBoxWrapper|SingBoxPlatform|libbox|flutter|AndroidRuntime|VpnException|VpnPermissionException)" \
  | tee "$LOG_FILE" &

LOGCAT_PID=$!
echo $LOGCAT_PID > "$PID_FILE"

echo "   ✅ Logcat запущен (PID: $LOGCAT_PID)"
echo "   📝 Логи сохраняются в: $LOG_FILE"

echo ""
echo "=========================================="
echo "  Мониторинг логов запущен!"
echo "=========================================="
echo ""
echo "📊 Для просмотра логов в реальном времени:"
echo "   tail -f $LOG_FILE"
echo ""
echo "📋 Для просмотра последних 100 строк:"
echo "   tail -100 $LOG_FILE"
echo ""
echo "🛑 Для остановки:"
echo "   kill $LOGCAT_PID"
echo "   или"
echo "   /opt/grani/scripts/stop_logcat_monitor.sh"
echo ""

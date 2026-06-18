#!/usr/bin/env bash
# Скрипт остановки мониторинга logcat
# Использование: /opt/grani/scripts/stop_logcat_monitor.sh

set -euo pipefail

LOG_DIR="/opt/grani/logs/android"
PID_FILE="${LOG_DIR}/logcat.pid"

echo "Остановка мониторинга logcat..."

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if ps -p $PID > /dev/null 2>&1; then
        kill $PID 2>/dev/null || true
        echo "✅ Logcat остановлен (PID: $PID)"
    else
        echo "ℹ️  Logcat не запущен"
    fi
    rm -f "$PID_FILE"
else
    echo "ℹ️  Logcat не запущен"
fi

# Остановка всех процессов logcat (на всякий случай)
pkill -f "adb.*logcat.*com.granivpn.mobile" 2>/dev/null || true

echo "Готово"

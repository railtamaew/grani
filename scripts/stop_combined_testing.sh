#!/usr/bin/env bash
# Скрипт остановки комбинированной системы тестирования
# Использование: /opt/grani/scripts/stop_combined_testing.sh

set -euo pipefail

echo "=========================================="
echo "  Остановка системы тестирования"
echo "=========================================="
echo ""

# Остановка logcat
echo "[1/3] Остановка logcat..."
if [ -f "/opt/grani/logs/android/logcat.pid" ]; then
    PID=$(cat "/opt/grani/logs/android/logcat.pid")
    if ps -p $PID > /dev/null 2>&1; then
        kill $PID 2>/dev/null || true
        echo "   ✅ Logcat остановлен"
    fi
    rm -f "/opt/grani/logs/android/logcat.pid"
else
    echo "   ℹ️  Logcat не запущен"
fi

# Остановка noVNC
echo ""
echo "[2/3] Остановка noVNC..."
/opt/grani/scripts/stop_novnc.sh

# Остановка эмулятора
echo ""
echo "[3/3] Остановка эмулятора..."
if pgrep -f "emulator.*grani_emulator" > /dev/null; then
    pkill -f "emulator.*grani_emulator"
    echo "   ✅ Эмулятор остановлен"
else
    echo "   ℹ️  Эмулятор не запущен"
fi

echo ""
echo "=========================================="
echo "  Система остановлена"
echo "=========================================="

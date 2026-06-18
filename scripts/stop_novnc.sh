#!/bin/bash
# Остановка websockify

NOVNC_PORT=${NOVNC_PORT:-6080}
PID_FILE="/tmp/websockify_$NOVNC_PORT.pid"

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if ps -p $PID > /dev/null 2>&1; then
        kill $PID
        echo "websockify остановлен"
    fi
    rm -f "$PID_FILE"
fi

pkill -f "websockify.*$NOVNC_PORT" 2>/dev/null || true

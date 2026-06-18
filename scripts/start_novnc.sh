#!/usr/bin/env bash
# Скрипт запуска noVNC веб-интерфейса для эмулятора
# Использование: /opt/grani/scripts/start_novnc.sh

set -euo pipefail

NOVNC_DIR="/opt/grani/emulator_web"
VNC_HOST="localhost"
VNC_PORT=5901
WEB_PORT=6080
PID_FILE="/tmp/websockify_${WEB_PORT}.pid"

echo "=========================================="
echo "  Запуск noVNC веб-интерфейса"
echo "=========================================="

# Проверка существующего процесса
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if ps -p $PID > /dev/null 2>&1; then
        echo "✅ noVNC уже запущен (PID: $PID)"
        echo ""
        echo "Веб-интерфейс доступен по адресу:"
        SERVER_IP=$(hostname -I | awk '{print $1}')
        echo "  http://${SERVER_IP}:${WEB_PORT}/vnc.html"
        echo "  или"
        echo "  http://localhost:${WEB_PORT}/vnc.html"
        exit 0
    fi
    rm -f "$PID_FILE"
fi

# Проверка VNC сервера
echo "[1/3] Проверка VNC сервера..."
if ! nc -z localhost $VNC_PORT 2>/dev/null; then
    echo "❌ VNC сервер не доступен на порту $VNC_PORT"
    echo ""
    echo "Запустите сначала эмулятор:"
    echo "  /opt/grani/scripts/start_emulator_with_vnc.sh"
    exit 1
fi
echo "   ✅ VNC сервер доступен"

# Проверка websockify
echo ""
echo "[2/3] Проверка websockify..."
if [ ! -d "$NOVNC_DIR/utils/websockify" ]; then
    echo "   Установка websockify..."
    cd "$NOVNC_DIR/utils"
    if [ ! -d "websockify" ]; then
        git clone https://github.com/novnc/websockify.git || {
            echo "❌ Не удалось клонировать websockify"
            exit 1
        }
    fi
fi

# Проверка Python3
if ! command -v python3 &> /dev/null; then
    echo "❌ Python3 не установлен"
    echo "Установите: apt-get install -y python3"
    exit 1
fi

# Запуск websockify
echo ""
echo "[3/3] Запуск websockify..."
cd "$NOVNC_DIR"

# Используем python3 websockify с --listen 0.0.0.0 для доступа извне
# websockify может быть установлен как пакет или в директории
if python3 -m websockify --help >/dev/null 2>&1; then
    # Используем как модуль Python
    python3 -m websockify \
      --web "$NOVNC_DIR" \
      --listen 0.0.0.0 \
      "${WEB_PORT}" \
      "${VNC_HOST}:${VNC_PORT}" \
      > /tmp/websockify.log 2>&1 &
elif [ -f "$NOVNC_DIR/utils/websockify/run" ]; then
    # Используем скрипт run
    python3 "$NOVNC_DIR/utils/websockify/run" \
      --web "$NOVNC_DIR" \
      --listen 0.0.0.0 \
      "${WEB_PORT}" \
      "${VNC_HOST}:${VNC_PORT}" \
      > /tmp/websockify.log 2>&1 &
elif [ -f "$NOVNC_DIR/utils/websockify/websockify/__main__.py" ]; then
    # Используем __main__.py
    python3 "$NOVNC_DIR/utils/websockify/websockify/__main__.py" \
      --web "$NOVNC_DIR" \
      --listen 0.0.0.0 \
      "${WEB_PORT}" \
      "${VNC_HOST}:${VNC_PORT}" \
      > /tmp/websockify.log 2>&1 &
else
    echo "❌ websockify не найден"
    exit 1
fi

WEBSOCKIFY_PID=$!
echo $WEBSOCKIFY_PID > "$PID_FILE"

sleep 3
if ! ps -p $WEBSOCKIFY_PID > /dev/null 2>&1; then
    echo "❌ Не удалось запустить websockify"
    echo "Логи:"
    cat /tmp/websockify.log
    exit 1
fi

echo "   ✅ websockify запущен (PID: $WEBSOCKIFY_PID)"

SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "=========================================="
echo "  noVNC веб-интерфейс запущен!"
echo "=========================================="
echo ""
echo "🌐 Откройте в браузере:"
echo "   http://${SERVER_IP}:${WEB_PORT}/vnc.html"
echo "   или"
echo "   http://localhost:${WEB_PORT}/vnc.html"
echo ""
echo "💡 В браузере вы увидите экран эмулятора"
echo "   Когда появится диалог разрешения VPN,"
echo "   нажмите 'Разрешить' мышью в браузере"
echo ""
echo "🛑 Для остановки: /opt/grani/scripts/stop_novnc.sh"
echo ""

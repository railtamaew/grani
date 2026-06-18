#!/bin/bash
# Скрипт для остановки всех сервисов разработки
# Использование: /opt/grani/scripts/stop_dev.sh

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

EMULATOR_NAME="grani_emulator"
VNC_DISPLAY=":1"
LOG_DIR="/opt/grani/logs"

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

echo "=========================================="
echo "  Остановка сервисов разработки"
echo "=========================================="
echo ""

# Остановка эмулятора
print_info "Остановка эмулятора..."
if pgrep -f "emulator.*$EMULATOR_NAME" > /dev/null; then
    EMULATOR_PIDS=$(pgrep -f "emulator.*$EMULATOR_NAME")
    for pid in $EMULATOR_PIDS; do
        kill $pid 2>/dev/null || true
        print_info "Остановлен процесс эмулятора: $pid"
    done
    # Ждем завершения
    sleep 3
    # Принудительная остановка если еще работает
    if pgrep -f "emulator.*$EMULATOR_NAME" > /dev/null; then
        pkill -9 -f "emulator.*$EMULATOR_NAME" 2>/dev/null || true
        print_warning "Принудительная остановка эмулятора"
    fi
    print_success "Эмулятор остановлен"
else
    print_info "Эмулятор не запущен"
fi

# Остановка ADB сервера (опционально)
read -p "Остановить ADB сервер? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    print_info "Остановка ADB сервера..."
    adb kill-server 2>/dev/null || true
    print_success "ADB сервер остановлен"
fi

# Остановка VNC
print_info "Остановка VNC сервера..."
if pgrep -f "vncserver.*$VNC_DISPLAY" > /dev/null; then
    vncserver -kill $VNC_DISPLAY > /dev/null 2>&1 || true
    print_success "VNC сервер остановлен"
elif pgrep -f "Xvnc.*$VNC_DISPLAY" > /dev/null; then
    pkill -f "Xvnc.*$VNC_DISPLAY" 2>/dev/null || true
    print_success "VNC сервер остановлен"
else
    print_info "VNC сервер не запущен"
fi

# Остановка Xvfb
print_info "Остановка Xvfb..."
if pgrep -f "Xvfb.*$VNC_DISPLAY" > /dev/null; then
    pkill -f "Xvfb.*$VNC_DISPLAY" 2>/dev/null || true
    print_success "Xvfb остановлен"
else
    print_info "Xvfb не запущен"
fi

# Остановка фонового logcat
print_info "Остановка фонового logcat..."
if [ -f "$LOG_DIR/logcat.pid" ]; then
    LOGCAT_PID=$(cat "$LOG_DIR/logcat.pid" 2>/dev/null || echo "")
    if [ -n "$LOGCAT_PID" ] && ps -p "$LOGCAT_PID" > /dev/null 2>&1; then
        kill "$LOGCAT_PID" 2>/dev/null || true
        print_success "Logcat остановлен"
    fi
    rm -f "$LOG_DIR/logcat.pid"
fi
pkill -f "adb.*logcat" 2>/dev/null || true

echo ""
echo "=========================================="
print_success "Все сервисы остановлены!"
echo "=========================================="



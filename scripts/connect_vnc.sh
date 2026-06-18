#!/bin/bash
# Скрипт для подключения VNC к эмулятору на Mac
# Использование: /opt/grani/scripts/connect_vnc.sh

set -e

# Цвета
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VNC_DISPLAY=":1"
VNC_PORT=5901
SERVER_IP="159.223.199.122"
SSH_USER="root"

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

echo "=========================================="
echo "  Подключение VNC к эмулятору"
echo "=========================================="
echo ""

# Проверка запущенного VNC
print_info "Проверка VNC сервера на сервере..."
if ssh $SSH_USER@$SERVER_IP "pgrep -f 'vncserver.*$VNC_DISPLAY' > /dev/null || pgrep -f 'Xvnc.*$VNC_DISPLAY' > /dev/null"; then
    print_success "VNC сервер запущен"
else
    print_warning "VNC сервер не запущен. Запустите: /opt/grani/scripts/start_emulator.sh"
    exit 1
fi

echo ""
print_info "Создание SSH туннеля для VNC..."
print_info "Сервер: $SSH_USER@$SERVER_IP"
print_info "Локальный порт: $VNC_PORT -> Удаленный порт: $VNC_PORT"
echo ""

# Проверка уже существующего туннеля
if lsof -ti:$VNC_PORT > /dev/null 2>&1; then
    print_warning "Порт $VNC_PORT уже используется"
    print_info "Остановите существующее подключение или используйте другой порт"
    exit 1
fi

echo "=========================================="
print_success "SSH туннель создан!"
echo "=========================================="
echo ""
print_info "Для подключения к VNC на Mac:"
echo ""
echo "1. Откройте Finder"
echo "2. Нажмите Cmd+K (или Переход -> Подключиться к серверу)"
echo "3. Введите: vnc://localhost:$VNC_PORT"
echo "4. Или используйте Screen Sharing:"
echo "   Откройте Screen Sharing и подключитесь к: localhost:$VNC_PORT"
echo ""
print_info "Альтернатива: Используйте VNC клиент (например, RealVNC Viewer)"
print_info "  Адрес: localhost:$VNC_PORT"
echo ""
print_warning "Оставьте это окно открытым для работы туннеля"
print_info "Для остановки нажмите Ctrl+C"
echo ""

# Создание SSH туннеля
ssh -L $VNC_PORT:localhost:$VNC_PORT -N $SSH_USER@$SERVER_IP



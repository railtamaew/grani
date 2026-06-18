#!/bin/bash

# Скрипт для быстрого деплоя на DigitalOcean
# Использование: ./deploy-to-digitalocean.sh YOUR_DROPLET_IP

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Проверка аргументов
if [ -z "$1" ]; then
    print_error "Использование: $0 YOUR_DROPLET_IP [USER]"
    print_error "Пример: $0 123.45.67.89 root"
    exit 1
fi

DROPLET_IP=$1
SSH_USER=${2:-root}
PROJECT_DIR="/opt/grani"

print_status "🚀 Начинаем деплой на DigitalOcean..."
print_status "IP: $DROPLET_IP"
print_status "User: $SSH_USER"

# Проверка SSH подключения
print_status "Проверка SSH подключения..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes $SSH_USER@$DROPLET_IP echo "OK" > /dev/null 2>&1; then
    print_error "Не удалось подключиться к серверу по SSH"
    print_error "Убедитесь, что:"
    print_error "  1. IP адрес правильный"
    print_error "  2. SSH ключ добавлен в сервер"
    print_error "  3. Порт 22 открыт"
    exit 1
fi

print_success "SSH подключение работает"

# Создание директории на сервере
print_status "Создание директории проекта на сервере..."
ssh $SSH_USER@$DROPLET_IP "mkdir -p $PROJECT_DIR"

# Загрузка проекта (через rsync, если доступен, иначе через scp)
print_status "Загрузка проекта на сервер..."

# Определяем корневую директорию проекта (на уровень выше server-config)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

if command -v rsync &> /dev/null; then
    print_status "Используем rsync для синхронизации..."
    rsync -avz --progress \
        --exclude 'node_modules' \
        --exclude '__pycache__' \
        --exclude '.git' \
        --exclude '*.pyc' \
        --exclude '.env' \
        --exclude 'venv' \
        --exclude '.venv' \
        --exclude 'build' \
        --exclude 'dist' \
        --exclude '.pytest_cache' \
        --exclude 'htmlcov' \
        "$PROJECT_ROOT/" $SSH_USER@$DROPLET_IP:$PROJECT_DIR/
else
    print_warning "rsync не найден, используем scp (может быть медленнее)..."
    scp -r "$PROJECT_ROOT"/* $SSH_USER@$DROPLET_IP:$PROJECT_DIR/
fi

print_success "Проект загружен на сервер"

# Запуск скрипта настройки на сервере
print_status "Запуск скрипта настройки на сервере..."
ssh $SSH_USER@$DROPLET_IP << 'ENDSSH'
    cd /opt/grani
    
    # Установка базовых пакетов
    apt update && apt install -y curl wget git docker.io docker-compose-plugin ufw fail2ban
    
    # Настройка Docker
    systemctl enable docker
    systemctl start docker
    
    # Запуск скрипта деплоя
    if [ -f "server-config/deploy-on-server.sh" ]; then
        chmod +x server-config/deploy-on-server.sh
        bash server-config/deploy-on-server.sh
    else
        echo "Скрипт deploy-on-server.sh не найден, выполните настройку вручную"
    fi
ENDSSH

print_success "✅ Деплой завершен!"
print_status ""
print_status "📝 Следующие шаги:"
print_status "  1. Подключитесь к серверу: ssh $SSH_USER@$DROPLET_IP"
print_status "  2. Настройте .env файл: cd $PROJECT_DIR/server-config && nano .env"
print_status "  3. Запустите контейнеры: cd $PROJECT_DIR/server-config/docker && docker compose up -d"
print_status "  4. Настройте Cursor для работы через SSH (см. docs/DIGITALOCEAN_DEPLOYMENT.md)"


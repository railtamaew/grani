#!/bin/bash
# Полный деплой: синхронизация + перезапуск контейнеров

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Настройки
SERVER_IP="159.223.199.122"
SERVER_USER="root"
SERVER_PATH="/opt/grani"
LOCAL_PATH="/Volumes/disk_rail/grani2"

print_status "🚀 Полный деплой на сервер..."

# 1. Проверка Git статуса
cd "${LOCAL_PATH}"
if [ -d ".git" ]; then
    UNCOMMITTED=$(git status --porcelain)
    if [ -n "$UNCOMMITTED" ]; then
        print_warning "⚠️  Есть незакоммиченные изменения:"
        git status --short
        read -p "Продолжить без коммита? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_error "Отменено. Сначала закоммитьте изменения."
            exit 1
        fi
    fi
fi

# 2. Полная синхронизация
print_status "Синхронизация проекта..."
"${LOCAL_PATH}/server-config/sync-to-server.sh"

# 3. Перезапуск контейнеров с пересборкой
print_status "Перезапуск контейнеров с пересборкой..."
ssh -o StrictHostKeyChecking=no ${SERVER_USER}@${SERVER_IP} << 'ENDSSH'
    cd /opt/grani/server-config/docker
    
    print_status() { echo -e "\033[0;34m[INFO]\033[0m $1"; }
    print_success() { echo -e "\033[0;32m[SUCCESS]\033[0m $1"; }
    
    print_status "Остановка контейнеров..."
    docker-compose down
    
    print_status "Сборка и запуск контейнеров..."
    docker-compose up -d --build
    
    print_status "Ожидание запуска..."
    sleep 10
    
    print_status "Статус контейнеров:"
    docker-compose ps
    
    print_status "Логи (последние 20 строк):"
    docker-compose logs --tail=20
ENDSSH

print_success "✅ Деплой завершен!"
print_status "Проверьте статус: ssh ${SERVER_USER}@${SERVER_IP} 'cd /opt/grani/server-config/docker && docker-compose ps'"

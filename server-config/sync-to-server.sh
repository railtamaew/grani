#!/bin/bash
# Скрипт для синхронизации проекта с сервером

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

# Проверка SSH доступа
print_status "Проверка SSH доступа..."
if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no ${SERVER_USER}@${SERVER_IP} "echo 'OK'" > /dev/null 2>&1; then
    print_error "Не удается подключиться к серверу ${SERVER_IP}"
    exit 1
fi
print_success "SSH доступ работает"

# Проверка что мы в правильной директории
if [ ! -f "${LOCAL_PATH}/.gitignore" ]; then
    print_error "Не найден .gitignore. Убедитесь что вы в корне проекта"
    exit 1
fi

# Исключения для rsync (не синхронизируем)
EXCLUDE_FILE=$(mktemp)
cat > "$EXCLUDE_FILE" << EOF
node_modules/
__pycache__/
*.pyc
*.pyo
*.pyd
.Python
venv/
.venv/
env/
.env
.env.local
.git/
.DS_Store
*.log
*.tmp
build/
dist/
*.tar.gz
*.zip
mobile-app/flutter/
mobile-app/.dart_tool/
mobile-app/.pub/
mobile-app/build/
admin-panel/node_modules/
admin-panel/build/
backend/__pycache__/
*.db
*.sqlite
*.sqlite3
EOF

print_status "Синхронизация проекта с сервером..."
print_warning "Это может занять несколько минут..."

# Синхронизация через rsync
rsync -avz \
    --delete \
    --exclude-from="$EXCLUDE_FILE" \
    --progress \
    -e "ssh -o StrictHostKeyChecking=no" \
    "${LOCAL_PATH}/" \
    ${SERVER_USER}@${SERVER_IP}:${SERVER_PATH}/

if [ $? -eq 0 ]; then
    print_success "Синхронизация завершена"
else
    print_error "Ошибка при синхронизации"
    rm -f "$EXCLUDE_FILE"
    exit 1
fi

rm -f "$EXCLUDE_FILE"

# Опционально: перезапуск контейнеров
read -p "Перезапустить Docker контейнеры? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    print_status "Перезапуск контейнеров..."
    ssh -o StrictHostKeyChecking=no ${SERVER_USER}@${SERVER_IP} << 'ENDSSH'
        cd /opt/grani/server-config/docker
        docker-compose down
        docker-compose up -d --build
        docker-compose ps
ENDSSH
    print_success "Контейнеры перезапущены"
fi

print_success "✅ Готово! Проект синхронизирован с сервером"



#!/bin/bash
# Скрипт для синхронизации только измененных файлов (быстро)

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

# Проверка что мы в git репозитории
if [ ! -d "${LOCAL_PATH}/.git" ]; then
    print_error "Не найден .git. Используйте sync-to-server.sh для полной синхронизации"
    exit 1
fi

# Получаем список измененных файлов
print_status "Поиск измененных файлов..."
cd "${LOCAL_PATH}"

# Файлы измененные в рабочей директории
CHANGED_FILES=$(git diff --name-only HEAD)
# Файлы добавленные в staging
STAGED_FILES=$(git diff --cached --name-only)

ALL_FILES=$(echo -e "${CHANGED_FILES}\n${STAGED_FILES}" | sort -u | grep -v '^$')

if [ -z "$ALL_FILES" ]; then
    print_warning "Нет измененных файлов для синхронизации"
    exit 0
fi

print_status "Найдено измененных файлов: $(echo "$ALL_FILES" | wc -l | tr -d ' ')"

# Исключаем файлы которые не нужно синхронизировать
FILTERED_FILES=""
for file in $ALL_FILES; do
    # Пропускаем файлы в .gitignore или временные
    if [[ "$file" == *"node_modules"* ]] || \
       [[ "$file" == *"__pycache__"* ]] || \
       [[ "$file" == *".env"* ]] || \
       [[ "$file" == *".git"* ]] || \
       [[ "$file" == *".DS_Store"* ]]; then
        continue
    fi
    
    if [ -f "$file" ]; then
        FILTERED_FILES="${FILTERED_FILES}${file}\n"
    fi
done

if [ -z "$FILTERED_FILES" ]; then
    print_warning "Нет файлов для синхронизации (все исключены)"
    exit 0
fi

# Синхронизация через rsync (только измененные файлы)
print_status "Синхронизация измененных файлов..."

echo -e "$FILTERED_FILES" | while IFS= read -r file; do
    if [ -n "$file" ] && [ -f "$file" ]; then
        print_status "  → $file"
        rsync -avz \
            -e "ssh -o StrictHostKeyChecking=no" \
            "${LOCAL_PATH}/${file}" \
            ${SERVER_USER}@${SERVER_IP}:${SERVER_PATH}/${file}
    fi
done

print_success "Синхронизация завершена"

# Опционально: перезапуск контейнеров
read -p "Перезапустить Docker контейнеры? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    print_status "Перезапуск контейнеров..."
    ssh -o StrictHostKeyChecking=no ${SERVER_USER}@${SERVER_IP} << 'ENDSSH'
        cd /opt/grani/server-config/docker
        docker-compose restart
        docker-compose ps
ENDSSH
    print_success "Контейнеры перезапущены"
fi

print_success "✅ Готово!"



#!/bin/bash
# Скрипт для безопасной миграции секретов без остановки сервиса
# Использование: ./safe_secrets_migration.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Проверка, что мы root или имеем sudo
if [ "$EUID" -ne 0 ]; then 
    print_error "Please run as root or with sudo"
    exit 1
fi

SECRETS_DIR="/etc/grani"
SECRETS_FILE="${SECRETS_DIR}/secrets.env"
BACKUP_DIR="${SECRETS_DIR}/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

print_status "Starting safe secrets migration..."

# Создаем директорию для секретов
mkdir -p "${SECRETS_DIR}"
mkdir -p "${BACKUP_DIR}"
chmod 700 "${SECRETS_DIR}"

# Проверяем существующий файл
if [ -f "${SECRETS_FILE}" ]; then
    print_warning "Secrets file already exists: ${SECRETS_FILE}"
    read -p "Backup existing file? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        BACKUP_FILE="${BACKUP_DIR}/secrets.env.${TIMESTAMP}"
        cp "${SECRETS_FILE}" "${BACKUP_FILE}"
        chmod 600 "${BACKUP_FILE}"
        print_success "Backed up to: ${BACKUP_FILE}"
    fi
else
    print_status "Creating new secrets file..."
    
    # Генерируем новый SECRET_KEY
    print_status "Generating new SECRET_KEY..."
    NEW_SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
    
    # Создаем файл из шаблона
    cat > "${SECRETS_FILE}" << EOF
# GRANI VPN Secrets - Generated ${TIMESTAMP}
# ВАЖНО: Этот файл содержит секреты. Храните его в безопасном месте.
# Права доступа: 600

# Database
# TODO: Заполните реальными значениями
DATABASE_URL=postgresql://granivpn_user:CHANGE_ME@postgres:5432/granivpn
POSTGRES_PASSWORD=CHANGE_ME

# Redis
REDIS_URL=redis://:CHANGE_ME@redis:6379/0
REDIS_PASSWORD=CHANGE_ME

# JWT Secret Key
SECRET_KEY=${NEW_SECRET_KEY}
SECRET_KEY_OLD=

# Email SMTP
SMTP_HOST=smtp.yandex.ru
SMTP_PORT=465
SMTP_USERNAME=CHANGE_ME
SMTP_PASSWORD=CHANGE_ME
SMTP_FROM_EMAIL=CHANGE_ME
SMTP_FROM_NAME=GRANI

# Environment
ENV=production
EOF
    
    chmod 600 "${SECRETS_FILE}"
    print_success "Created secrets file: ${SECRETS_FILE}"
    print_warning "⚠️  IMPORTANT: Fill in all CHANGE_ME values before using!"
    print_warning "⚠️  New SECRET_KEY generated: ${NEW_SECRET_KEY}"
    print_warning "⚠️  Save this key securely!"
fi

print_status "Migration setup complete."
print_status "Next steps:"
echo "  1. Edit ${SECRETS_FILE} and fill in all secrets"
echo "  2. Update your application to use ${SECRETS_FILE}"
echo "  3. For JWT rotation: set SECRET_KEY_OLD to current key"
echo "  4. Restart application gracefully"
echo "  5. Monitor logs for any issues"

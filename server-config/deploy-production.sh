#!/bin/bash

# Автоматический деплой GraniVPN на продакшн сервер
set -e

echo "🚀 Начинаем деплой GraniVPN на продакшн сервер..."

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для вывода цветного текста
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

# Проверка root прав
if [ "$EUID" -ne 0 ]; then
    print_error "Пожалуйста, запустите скрипт с правами root (sudo)"
    exit 1
fi

# Получение информации о сервере
SERVER_IP=$(curl -s ifconfig.me)
print_status "IP сервера: $SERVER_IP"

# 1. Обновление системы
print_status "Обновление системы..."
apt update && apt upgrade -y

# 2. Установка зависимостей
print_status "Установка Docker и зависимостей..."
apt install -y curl wget git ufw fail2ban

# Установка Docker
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    systemctl enable docker
    systemctl start docker
    print_success "Docker установлен"
else
    print_success "Docker уже установлен"
fi

# Установка Docker Compose
if ! command -v docker-compose &> /dev/null; then
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    print_success "Docker Compose установлен"
else
    print_success "Docker Compose уже установлен"
fi

# 3. Настройка WireGuard
print_status "Установка WireGuard..."
apt install -y wireguard wireguard-tools
modprobe wireguard

# Включение IP forwarding
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf
sysctl -p

# 4. Настройка файрвола
print_status "Настройка файрвола..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# Разрешаем SSH, HTTP, HTTPS
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp

# Разрешаем WireGuard
ufw allow 51820/udp

# Разрешаем внутренние соединения Docker
ufw allow from 172.16.0.0/12
ufw allow from 192.168.0.0/16

ufw --force enable
print_success "Файрвол настроен"

# 5. Клонирование проекта
print_status "Клонирование проекта..."
cd /opt
if [ -d "granivpn" ]; then
    cd granivpn
    git pull
    print_success "Проект обновлен"
else
    git clone https://github.com/YOUR_USERNAME/granivpn.git
    cd granivpn
    print_success "Проект клонирован"
fi

# 6. Настройка переменных окружения
print_status "Настройка переменных окружения..."
cd server-config

if [ ! -f ".env" ]; then
    cp env.example .env
    
    # Генерация секретного ключа
    SECRET_KEY=$(openssl rand -hex 32)
    sed -i "s/your-super-secret-key-here-change-this/$SECRET_KEY/" .env
    
    # Установка IP сервера
    sed -i "s/YOUR_SERVER_IP/$SERVER_IP/" .env
    
    print_warning "⚠️  ВАЖНО! Отредактируйте файл .env:"
    print_warning "   - Замените granilink.com на ваш домен"
    print_warning "   - Настройте платежные системы"
    print_warning "   - Проверьте все настройки"
    
    nano .env
fi

# 7. Создание сертификатов SSL
print_status "Настройка SSL сертификатов..."
if ! command -v certbot &> /dev/null; then
    apt install -y certbot python3-certbot-nginx
fi

# Запрос домена у пользователя
read -p "Введите ваш домен (например: granilink.com): " DOMAIN
read -p "Введите email для SSL сертификата: " EMAIL

# Получение сертификата
certbot certonly --standalone -d $DOMAIN -d api.$DOMAIN -d admin.$DOMAIN -d app.$DOMAIN --email $EMAIL --agree-tos --non-interactive

# Обновление домена в .env
sed -i "s/granilink.com/$DOMAIN/" .env

# 8. Сборка и запуск Docker контейнеров
print_status "Сборка и запуск Docker контейнеров..."
cd docker
docker-compose down --remove-orphans
docker-compose pull
docker-compose build --no-cache
docker-compose up -d

# Проверка статуса контейнеров
sleep 10
docker-compose ps

# 9. Инициализация базы данных
print_status "Инициализация базы данных..."
docker-compose exec -T api python -c "
from core.database import engine, Base
from models import user, server, subscription, payment
Base.metadata.create_all(bind=engine)
print('База данных инициализирована')
"

# 10. Создание суперпользователя
print_status "Создание администратора..."
docker-compose exec -T api python -c "
import asyncio
from services.auth_service import AuthService
from core.database import get_session

async def create_admin():
    async for session in get_session():
        auth_service = AuthService(session)
        try:
            admin = await auth_service.create_user(
                email='admin@$DOMAIN',
                password='admin123',
                is_admin=True
            )
            print(f'Администратор создан: admin@$DOMAIN / admin123')
        except Exception as e:
            print(f'Администратор уже существует или ошибка: {e}')
        break

asyncio.run(create_admin())
"

# 11. Настройка автоматического обновления SSL
print_status "Настройка автоматического обновления SSL..."
(crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet") | crontab -

# 12. Настройка мониторинга
print_status "Настройка мониторинга..."
docker-compose exec -T api pip install prometheus-client
docker-compose restart api

print_success "🎉 Деплой завершен успешно!"
print_success ""
print_success "📝 Информация о развертывании:"
print_success "   • API: https://api.$DOMAIN"
print_success "   • Admin Panel: https://admin.$DOMAIN" 
print_success "   • Mobile App: https://app.$DOMAIN"
print_success "   • Flower (Celery): https://$DOMAIN:5555"
print_success "   • Администратор: admin@$DOMAIN / admin123"
print_success ""
print_warning "🔧 Следующие шаги:"
print_warning "   1. Настройте DNS записи для поддоменов"
print_warning "   2. Обновите CORS_ORIGINS в .env если нужно"
print_warning "   3. Настройте платежные системы"
print_warning "   4. Протестируйте все компоненты"
print_warning ""
print_status "📋 Полезные команды:"
print_status "   • Логи: docker-compose logs -f"
print_status "   • Рестарт: docker-compose restart"
print_status "   • Статус: docker-compose ps"
print_status "   • Обновление: git pull && docker-compose up -d --build"









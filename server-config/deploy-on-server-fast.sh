#!/bin/bash
# Оптимизированный скрипт развертывания - без долгого обновления системы

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

# Проверка root прав
if [ "$EUID" -ne 0 ]; then
    print_error "Пожалуйста, запустите скрипт с правами root (sudo)"
    exit 1
fi

print_status "🚀 Быстрое развёртывание GraniVPN на сервере..."

# Получение IP сервера
SERVER_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
print_status "IP сервера: $SERVER_IP"

# 1. Быстрое обновление только репозиториев (без upgrade)
print_status "Обновление списка пакетов (быстро)..."
apt update -qq || print_warning "apt update завершился с предупреждениями"

# 2. Установка только необходимых зависимостей
print_status "Установка минимальных зависимостей..."
DEBIAN_FRONTEND=noninteractive apt install -y -qq curl wget git ufw fail2ban || print_warning "Некоторые пакеты не установились"

# 3. Установка Docker (быстро, без обновления системы)
print_status "Установка Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    systemctl enable docker
    systemctl start docker
    print_success "Docker установлен"
else
    print_success "Docker уже установлен: $(docker --version)"
fi

# 4. Установка Docker Compose
print_status "Установка Docker Compose..."
if ! command -v docker-compose &> /dev/null; then
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    print_success "Docker Compose установлен"
else
    print_success "Docker Compose уже установлен: $(docker-compose --version)"
fi

# 5. Настройка WireGuard
print_status "Установка WireGuard..."
DEBIAN_FRONTEND=noninteractive apt install -y -qq wireguard wireguard-tools || print_warning "WireGuard установлен с предупреждениями"
modprobe wireguard || true

# Включение IP forwarding
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi
if ! grep -q "net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf; then
    echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf
fi
sysctl -p > /dev/null 2>&1 || true

# 6. Настройка файрвола
print_status "Настройка файрвола..."
ufw --force reset 2>/dev/null || true
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

# 7. Проверка наличия проекта
if [ ! -d "/opt/grani" ]; then
    print_error "Проект не найден в /opt/grani"
    exit 1
fi

cd /opt/grani

# 8. Настройка переменных окружения
print_status "Настройка переменных окружения..."
cd server-config

if [ ! -f ".env" ]; then
    if [ -f "env.example" ]; then
        cp env.example .env
        
        # Генерация секретного ключа
        SECRET_KEY=$(openssl rand -hex 32)
        sed -i "s/your-super-secret-key-here-change-this/$SECRET_KEY/" .env
        
        # Установка IP сервера
        sed -i "s/YOUR_SERVER_IP/$SERVER_IP/" .env
        
        print_success "Файл .env создан из env.example"
        print_warning "⚠️  ВАЖНО! Отредактируйте файл .env:"
        print_warning "   - Замените granilink.com на ваш домен"
        print_warning "   - Настройте платежные системы"
        print_warning "   - Проверьте все настройки"
        
        # Запрашиваем домен
        read -p "Введите ваш домен (например: granilink.com) или нажмите Enter для пропуска: " DOMAIN
        if [ ! -z "$DOMAIN" ]; then
            sed -i "s/granilink.com/$DOMAIN/g" .env
            print_success "Домен обновлён: $DOMAIN"
        fi
    else
        print_error "Файл env.example не найден!"
        exit 1
    fi
else
    print_success "Файл .env уже существует"
fi

# 9. Установка Certbot для SSL
print_status "Проверка Certbot..."
if ! command -v certbot &> /dev/null; then
    DEBIAN_FRONTEND=noninteractive apt install -y -qq certbot python3-certbot-nginx || print_warning "Certbot установлен с предупреждениями"
    print_success "Certbot установлен"
else
    print_success "Certbot уже установлен"
fi

# 10. Сборка и запуск Docker контейнеров
print_status "Сборка и запуск Docker контейнеров..."
cd docker

# Остановка существующих контейнеров
docker-compose down --remove-orphans 2>/dev/null || true

# Загрузка образов и сборка
print_status "Загрузка Docker образов..."
docker-compose pull || print_warning "Некоторые образы не найдены, будет выполнена сборка"

print_status "Сборка контейнеров..."
docker-compose build --no-cache

print_status "Запуск контейнеров..."
docker-compose up -d

# Проверка статуса контейнеров
sleep 10
print_status "Статус контейнеров:"
docker-compose ps

# 11. Инициализация базы данных
print_status "Ожидание готовности базы данных..."
sleep 15

print_status "Инициализация базы данных..."
docker-compose exec -T api python -c "
from core.database import engine, Base
from models import user, server, subscription, payment
Base.metadata.create_all(bind=engine)
print('✅ База данных инициализирована')
" 2>/dev/null || print_warning "База данных уже инициализирована или ошибка при инициализации"

# 12. Создание суперпользователя
print_status "Создание администратора..."
DOMAIN_FROM_ENV=$(grep "^DOMAIN=" ../.env | cut -d'=' -f2 | tr -d '"' || echo "granilink.com")
ADMIN_EMAIL="admin@${DOMAIN_FROM_ENV}"

docker-compose exec -T api python -c "
import asyncio
import sys
sys.path.insert(0, '/app')

try:
    from services.auth_service import AuthService
    from core.database import get_session
    
    async def create_admin():
        async for session in get_session():
            auth_service = AuthService(session)
            try:
                admin = await auth_service.create_user(
                    email='$ADMIN_EMAIL',
                    password='admin123',
                    is_admin=True
                )
                print(f'✅ Администратор создан: $ADMIN_EMAIL / admin123')
            except Exception as e:
                print(f'⚠️  Администратор уже существует или ошибка: {e}')
            break
    
    asyncio.run(create_admin())
except Exception as e:
    print(f'⚠️  Ошибка при создании администратора: {e}')
    print('Вы можете создать администратора вручную позже')
" 2>/dev/null || print_warning "Не удалось создать администратора автоматически. Создайте вручную позже."

# 13. Настройка автоматического обновления SSL
print_status "Настройка автоматического обновления SSL..."
(crontab -l 2>/dev/null | grep -v "certbot renew" ; echo "0 12 * * * /usr/bin/certbot renew --quiet") | crontab -
print_success "Автоматическое обновление SSL настроено"

# Итоговая информация
print_success ""
print_success "🎉 Быстрое развертывание завершено!"
print_success ""
print_success "📝 Информация о развертывании:"
print_success "   • Сервер IP: $SERVER_IP"
if [ ! -z "$DOMAIN" ]; then
    print_success "   • API: https://api.$DOMAIN"
    print_success "   • Admin Panel: https://admin.$DOMAIN" 
    print_success "   • Mobile App: https://app.$DOMAIN"
fi
print_success "   • Администратор: $ADMIN_EMAIL / admin123"
print_success ""
print_warning "⚠️  ВАЖНО: Полное обновление системы можно выполнить позже:"
print_warning "   apt upgrade -y"
print_warning ""
print_warning "🔧 Следующие шаги:"
print_warning "   1. Настройте DNS записи для поддоменов (если есть домен)"
print_warning "   2. Получите SSL сертификаты: certbot certonly --standalone -d DOMAIN"
print_warning "   3. Обновите CORS_ORIGINS в .env если нужно"
print_warning "   4. Настройте платежные системы в .env"
print_warning "   5. Протестируйте все компоненты"
print_warning ""
print_status "📋 Полезные команды:"
print_status "   • Логи: docker-compose logs -f"
print_status "   • Рестарт: docker-compose restart"
print_status "   • Статус: docker-compose ps"
print_status "   • Остановка: docker-compose down"
print_status "   • Обновление: git pull && docker-compose up -d --build"




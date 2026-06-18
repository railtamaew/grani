#!/bin/bash

# Скрипт настройки WireGuard на VPN сервере (94.131.107.227)
# Запускать на сервере от root пользователя

set -e

SERVER_IP="94.131.107.227"
WG_PORT="51820"
WG_INTERFACE="wg0"
WG_NETWORK="10.0.0.0/24"

echo "=========================================="
echo "НАСТРОЙКА WIREGUARD НА СЕРВЕРЕ"
echo "=========================================="
echo ""

# Цвета
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Проверка root
if [ "$EUID" -ne 0 ]; then 
    print_error "Запустите скрипт от root пользователя"
    exit 1
fi

# 1. Установка WireGuard
print_status "Установка WireGuard..."
if ! command -v wg &> /dev/null; then
    apt-get update
    apt-get install -y wireguard wireguard-tools
    print_status "WireGuard установлен"
else
    print_status "WireGuard уже установлен: $(wg --version)"
fi

# 2. Включение IP forwarding
print_status "Настройка IP forwarding..."
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    print_status "IP forwarding добавлен в sysctl.conf"
fi
if ! grep -q "net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf; then
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    print_status "IPv6 forwarding добавлен в sysctl.conf"
fi
sysctl -p > /dev/null 2>&1
print_status "IP forwarding включен"

# 3. Создание директории
print_status "Создание директории WireGuard..."
mkdir -p /etc/wireguard
cd /etc/wireguard

# 4. Генерация ключей (если еще не созданы)
if [ ! -f "server_private.key" ]; then
    print_status "Генерация ключей сервера..."
    wg genkey | tee server_private.key | wg pubkey > server_public.key
    chmod 600 server_private.key
    chmod 644 server_public.key
    print_status "Ключи сгенерированы"
    
    SERVER_PUBLIC_KEY=$(cat server_public.key)
    print_status "Публичный ключ сервера: $SERVER_PUBLIC_KEY"
    print_warning "Сохраните этот ключ для обновления базы данных!"
else
    print_status "Ключи уже существуют"
    SERVER_PUBLIC_KEY=$(cat server_public.key)
    print_status "Публичный ключ сервера: $SERVER_PUBLIC_KEY"
fi

# 5. Создание конфигурации WireGuard
print_status "Создание конфигурации WireGuard..."
SERVER_PRIVATE_KEY=$(cat server_private.key)

# Определяем основной сетевой интерфейс
MAIN_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -z "$MAIN_INTERFACE" ]; then
    MAIN_INTERFACE="eth0"
fi

cat > wg0.conf << EOF
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = 10.0.0.1/24
ListenPort = $WG_PORT
PostUp = iptables -A FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -t nat -D POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE

# DNS
DNS = 8.8.8.8, 8.8.4.4

# MTU
MTU = 1420

# Сохранение конфигурации
SaveConfig = true
EOF

chmod 600 wg0.conf
print_status "Конфигурация создана: /etc/wireguard/wg0.conf"

# 6. Настройка firewall
print_status "Настройка firewall..."
if command -v ufw &> /dev/null; then
    ufw allow $WG_PORT/udp comment "WireGuard" 2>/dev/null || true
    print_status "Порт $WG_PORT/udp открыт в firewall"
else
    print_warning "UFW не установлен, настройте firewall вручную"
fi

# 7. Запуск WireGuard
print_status "Запуск WireGuard..."
if wg show $WG_INTERFACE &> /dev/null; then
    print_status "WireGuard уже запущен"
    wg-quick down $WG_INTERFACE 2>/dev/null || true
fi

wg-quick up $WG_INTERFACE
print_status "WireGuard запущен"

# 8. Включение автозапуска
print_status "Настройка автозапуска..."
systemctl enable wg-quick@$WG_INTERFACE 2>/dev/null || true
print_status "Автозапуск настроен"

# 9. Проверка статуса
print_status "Проверка статуса WireGuard..."
sleep 2
if wg show $WG_INTERFACE &> /dev/null; then
    print_status "WireGuard работает корректно"
    echo ""
    echo "Информация о интерфейсе:"
    wg show $WG_INTERFACE
    echo ""
    echo "IP адреса:"
    ip addr show $WG_INTERFACE
else
    print_error "WireGuard не запустился"
    exit 1
fi

# 10. Итоговая информация
echo ""
echo "=========================================="
echo "НАСТРОЙКА ЗАВЕРШЕНА"
echo "=========================================="
echo ""
echo "Сервер: $SERVER_IP"
echo "Порт: $WG_PORT"
echo "Интерфейс: $WG_INTERFACE"
echo "Сеть: $WG_NETWORK"
echo "Публичный ключ: $SERVER_PUBLIC_KEY"
echo ""
print_warning "ВАЖНО: Обновите публичный ключ в базе данных!"
echo "Выполните на локальной машине:"
echo "  python3 backend/scripts/update_server_keys.py"
echo ""
print_status "WireGuard готов к работе!"



#!/bin/bash

# Скрипт для настройки SSH и развёртывания через DigitalOcean API
# Использование: bash setup-ssh-and-deploy.sh

set -e

SERVER_IP="143.110.238.126"
ARCHIVE="/tmp/granivpn-deploy-1762453706.tar.gz"
DO_TOKEN=$(grep DIGITALOCEAN_TOKEN server-config/.env.local 2>/dev/null | cut -d'=' -f2 || echo "")

if [ -z "$DO_TOKEN" ]; then
    echo "❌ DigitalOcean токен не найден в server-config/.env.local"
    exit 1
fi

echo "🔑 Настройка SSH через DigitalOcean API..."

# Получение публичного SSH ключа
SSH_KEY=$(cat ~/.ssh/id_rsa.pub 2>/dev/null || echo "")

if [ -z "$SSH_KEY" ]; then
    echo "❌ SSH ключ не найден в ~/.ssh/id_rsa.pub"
    exit 1
fi

echo "✅ SSH ключ найден"

# Установка doctl если нужно
if ! command -v doctl &> /dev/null; then
    echo "📦 Установка doctl..."
    cd /tmp
    wget https://github.com/digitalocean/doctl/releases/download/v1.104.0/doctl-1.104.0-darwin-amd64.tar.gz
    tar xf doctl-1.104.0-darwin-amd64.tar.gz
    sudo mv doctl /usr/local/bin
    echo "✅ doctl установлен"
fi

# Авторизация в DigitalOcean
echo "🔐 Авторизация в DigitalOcean..."
doctl auth init -t "$DO_TOKEN"

# Получение ID дроплета
echo "🔍 Поиск дроплета..."
DROPLET_ID=$(doctl compute droplet list --format ID,PublicIPv4 --no-header | grep "$SERVER_IP" | awk '{print $1}')

if [ -z "$DROPLET_ID" ]; then
    echo "❌ Дроплет с IP $SERVER_IP не найден"
    exit 1
fi

echo "✅ Дроплет найден: ID=$DROPLET_ID"

# Проверка существования SSH ключа в DigitalOcean
SSH_KEY_NAME="granivpn-deploy-key"
EXISTING_KEY=$(doctl compute ssh-key list --format ID,Name --no-header | grep "$SSH_KEY_NAME" | awk '{print $1}' || echo "")

if [ -z "$EXISTING_KEY" ]; then
    echo "📝 Добавление SSH ключа в DigitalOcean..."
    SSH_KEY_ID=$(doctl compute ssh-key import "$SSH_KEY_NAME" --public-key-file ~/.ssh/id_rsa.pub --format ID --no-header)
    echo "✅ SSH ключ добавлен: ID=$SSH_KEY_ID"
else
    SSH_KEY_ID=$EXISTING_KEY
    echo "✅ SSH ключ уже существует: ID=$SSH_KEY_ID"
fi

echo ""
echo "📤 Загрузка проекта на сервер..."
scp -o StrictHostKeyChecking=no "$ARCHIVE" root@$SERVER_IP:/tmp/

echo ""
echo "🚀 Запуск развёртывания на сервере..."
ssh -o StrictHostKeyChecking=no root@$SERVER_IP << 'ENDSSH'
set -e

echo "📦 Распаковка проекта..."
mkdir -p /opt/grani
cd /opt/grani
tar -xzf /tmp/granivpn-deploy-*.tar.gz --strip-components=1
rm -f /tmp/granivpn-deploy-*.tar.gz

echo "✅ Проект распакован"

if [ -f "server-config/deploy-on-server.sh" ]; then
    echo "🚀 Запуск скрипта развёртывания..."
    cd server-config
    bash deploy-on-server.sh
else
    echo "⚠️  Скрипт не найден, выполните вручную"
fi

ENDSSH

echo ""
echo "✅ Развёртывание завершено!"




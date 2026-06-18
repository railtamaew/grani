#!/bin/bash
# Скрипт для настройки SSH доступа к дроплету
# Пробует несколько методов для добавления SSH ключа

set -e

SERVER_IP="143.110.238.126"
DROPLET_ID="527544631"
SSH_KEY_ID="51792189"  # ID ключа "ключ06.11" в DigitalOcean

echo "🔍 Диагностика SSH доступа..."
echo ""

# Проверка текущего состояния
echo "1. Проверка SSH ключей на дроплете..."
CURRENT_KEYS=$(doctl compute droplet get $DROPLET_ID -o json | python3 -c "import sys, json; d=json.load(sys.stdin); print(len(d[0].get('ssh_keys', [])))" 2>/dev/null || echo "0")
echo "   Найдено SSH ключей: $CURRENT_KEYS"

if [ "$CURRENT_KEYS" = "0" ]; then
    echo "   ⚠️  На дроплете нет SSH ключей!"
    echo ""
    echo "📋 Решения:"
    echo ""
    echo "Вариант A: Использовать веб-консоль DigitalOcean"
    echo "   1. Откройте: https://cloud.digitalocean.com/droplets/$DROPLET_ID"
    echo "   2. Нажмите 'Access' → 'Launch Droplet Console'"
    echo "   3. Выполните команды:"
    echo ""
    cat ~/.ssh/id_rsa.pub | awk '{print "      echo '\''" $0 "'\'' >> ~/.ssh/authorized_keys"}'
    echo "      chmod 600 ~/.ssh/authorized_keys"
    echo ""
    echo "Вариант B: Использовать пароль root (если был установлен)"
    echo "   Подключитесь: ssh root@$SERVER_IP"
    echo "   И выполните те же команды"
    echo ""
    echo "Вариант C: Пересоздать дроплет с SSH ключом"
    echo "   ⚠️  ВНИМАНИЕ: Это удалит все данные!"
    echo "   Выполните:"
    echo "   doctl compute droplet delete $DROPLET_ID"
    echo "   doctl compute droplet create ubuntu-s-1vcpu-2gb-amd-sfo3-01 \\"
    echo "     --size s-1vcpu-2gb \\"
    echo "     --image ubuntu-22-04-x64 \\"
    echo "     --region sfo3 \\"
    echo "     --ssh-keys $SSH_KEY_ID \\"
    echo "     --wait"
    echo ""
    exit 1
fi

echo ""
echo "2. Проверка SSH подключения..."
if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$SERVER_IP "echo 'SSH работает!'" 2>/dev/null; then
    echo "   ✅ SSH подключение работает!"
    exit 0
else
    echo "   ❌ SSH подключение не работает"
    echo ""
    echo "Попробуйте подключиться вручную:"
    echo "   ssh root@$SERVER_IP"
    echo ""
    exit 1
fi




#!/bin/bash
# Скрипт для добавления SSH ключа на сервер вручную
# Использование: скопируйте публичный ключ и выполните команды на сервере

set -e

echo "🔑 Инструкция по добавлению SSH ключа на сервер"
echo ""
echo "Вариант 1: Через веб-консоль DigitalOcean"
echo "1. Откройте https://cloud.digitalocean.com/droplets/527544631"
echo "2. Нажмите 'Access' → 'Launch Droplet Console'"
echo "3. Войдите в систему (если потребуется пароль)"
echo "4. Выполните следующие команды:"
echo ""
echo "---"
echo "mkdir -p ~/.ssh"
echo "chmod 700 ~/.ssh"
echo "echo '$(cat ~/.ssh/id_rsa.pub)' >> ~/.ssh/authorized_keys"
echo "chmod 600 ~/.ssh/authorized_keys"
echo "---"
echo ""
echo "Вариант 2: Если у вас есть пароль root"
echo "Подключитесь по SSH с паролем и выполните те же команды"
echo ""
echo "Вариант 3: Через doctl (требует пересоздания дроплета)"
echo "⚠️  ВНИМАНИЕ: Это удалит все данные на дроплете!"
echo ""

PUBLIC_KEY=$(cat ~/.ssh/id_rsa.pub 2>/dev/null || echo "")

if [ ! -z "$PUBLIC_KEY" ]; then
    echo "📋 Ваш публичный SSH ключ:"
    echo ""
    echo "$PUBLIC_KEY"
    echo ""
    echo "Скопируйте этот ключ и добавьте его на сервер одним из способов выше."
else
    echo "❌ SSH ключ не найден в ~/.ssh/id_rsa.pub"
fi




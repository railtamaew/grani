#!/bin/bash

# Скрипт для безопасного сохранения DigitalOcean токена
# Использование: ./save-do-token.sh

set -e

echo "🔐 Сохранение DigitalOcean токена"
echo ""

# Проверка существования директории
if [ ! -d "server-config" ]; then
    echo "❌ Ошибка: Запустите скрипт из корня проекта"
    exit 1
fi

# Запрос токена
read -sp "Введите ваш DigitalOcean API токен: " DO_TOKEN
echo ""

if [ -z "$DO_TOKEN" ]; then
    echo "❌ Ошибка: Токен не может быть пустым"
    exit 1
fi

# Создание .env.local файла
ENV_FILE="server-config/.env.local"

# Проверка существования файла
if [ -f "$ENV_FILE" ]; then
    read -p "Файл $ENV_FILE уже существует. Перезаписать? (y/n): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Отменено"
        exit 0
    fi
fi

# Сохранение токена
echo "DIGITALOCEAN_TOKEN=$DO_TOKEN" > "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo "✅ Токен сохранен в $ENV_FILE"
echo "✅ Файл защищен от чтения другими пользователями (chmod 600)"
echo ""
echo "⚠️  ВАЖНО:"
echo "   - Файл $ENV_FILE уже в .gitignore"
echo "   - НЕ коммитьте этот файл в Git!"
echo "   - Храните токен в безопасном месте"
echo ""







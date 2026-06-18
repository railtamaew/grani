#!/bin/bash
# Скрипт для применения конфигурации nginx с /admin на granilink.com

set -e

echo "=== Применение конфигурации nginx ==="

# Путь к конфигурации
CONFIG_FILE="/opt/grani/server-config/nginx/production.conf"
NGINX_SITES_DIR="/etc/nginx/sites-available"
NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"
SITE_NAME="granivpn-production"

# Проверяем наличие nginx
if ! command -v nginx &> /dev/null; then
    echo "❌ Nginx не установлен. Установите: sudo apt install nginx"
    exit 1
fi

# Создаем backup текущей конфигурации
if [ -f "$NGINX_SITES_DIR/$SITE_NAME" ]; then
    BACKUP_FILE="${NGINX_SITES_DIR}/${SITE_NAME}.backup.$(date +%Y%m%d_%H%M%S)"
    sudo cp "$NGINX_SITES_DIR/$SITE_NAME" "$BACKUP_FILE"
    echo "✅ Создан backup: $BACKUP_FILE"
fi

# Копируем новую конфигурацию
echo "Копирование конфигурации..."
sudo cp "$CONFIG_FILE" "$NGINX_SITES_DIR/$SITE_NAME"

# Создаем символическую ссылку
if [ ! -L "$NGINX_ENABLED_DIR/$SITE_NAME" ]; then
    sudo ln -s "$NGINX_SITES_DIR/$SITE_NAME" "$NGINX_ENABLED_DIR/$SITE_NAME"
    echo "✅ Создана ссылка в sites-enabled"
fi

# Удаляем default если есть
if [ -f "$NGINX_ENABLED_DIR/default" ]; then
    sudo rm "$NGINX_ENABLED_DIR/default"
    echo "✅ Удален default site"
fi

# Проверяем конфигурацию
echo "Проверка конфигурации..."
if sudo nginx -t; then
    echo "✅ Конфигурация валидна"
    
    # Перезагружаем nginx
    echo "Перезагрузка nginx..."
    if sudo systemctl reload nginx 2>/dev/null || sudo service nginx reload 2>/dev/null; then
        echo "✅ Nginx перезагружен"
    else
        echo "❌ Ошибка при перезагрузке nginx"
        exit 1
    fi
else
    echo "❌ Ошибка в конфигурации nginx!"
    if [ -f "$BACKUP_FILE" ]; then
        echo "Откатываем изменения..."
        sudo cp "$BACKUP_FILE" "$NGINX_SITES_DIR/$SITE_NAME"
        sudo nginx -t && sudo systemctl reload nginx
    fi
    exit 1
fi

echo ""
echo "✅ Конфигурация применена успешно!"
echo ""
echo "Проверьте доступность:"
echo "  curl -I https://granilink.com/admin"
echo "  curl -I https://granilink.com/api/health"




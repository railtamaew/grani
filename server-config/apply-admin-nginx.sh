#!/bin/bash
# Скрипт для применения конфигурации /admin на granilink.com

set -e

echo "=== Настройка админ-панели на /admin ==="

# Проверяем, что мы на правильном сервере
if [ ! -f /etc/nginx/nginx.conf ] && [ ! -d /etc/nginx/sites-enabled ]; then
    echo "❌ Nginx не найден или не установлен"
    exit 1
fi

# Определяем где находится конфигурация
NGINX_CONF=""
if [ -f /etc/nginx/nginx.conf ]; then
    NGINX_CONF="/etc/nginx/nginx.conf"
elif [ -d /etc/nginx/sites-enabled ]; then
    # Ищем конфигурацию для granilink.com
    NGINX_CONF=$(grep -r "server_name.*granilink.com" /etc/nginx/sites-enabled/* | cut -d: -f1 | head -1)
fi

if [ -z "$NGINX_CONF" ]; then
    echo "❌ Не найдена конфигурация nginx для granilink.com"
    echo "Создайте файл конфигурации вручную"
    exit 1
fi

echo "✅ Найдена конфигурация: $NGINX_CONF"

# Создаем backup
cp "$NGINX_CONF" "${NGINX_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
echo "✅ Создан backup: ${NGINX_CONF}.backup.*"

# Добавляем location /admin в конфигурацию для granilink.com
# Нужно найти server блок для granilink.com и добавить location перед location /

ADMIN_LOCATION='
        # Админ-панель на /admin
        location /admin {
            # Проксируем на Netlify
            proxy_pass https://spectacular-begonia-477baa.netlify.app;
            proxy_set_header Host spectacular-begonia-477baa.netlify.app;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_ssl_verify off;
            
            # Для SPA нужно обрабатывать все пути
            proxy_redirect off;
            
            # Таймауты
            proxy_connect_timeout 60s;
            proxy_send_timeout 60s;
            proxy_read_timeout 60s;
        }'

# Проверяем, что location /admin еще не добавлен
if grep -q "location /admin" "$NGINX_CONF"; then
    echo "⚠️  location /admin уже существует в конфигурации"
    read -p "Перезаписать? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Отменено"
        exit 0
    fi
fi

# Добавляем location /admin перед location /
# Это делается через sed или можно использовать готовый файл
if [ -f /opt/grani/server-config/nginx/nginx.conf ]; then
    echo "✅ Используем готовую конфигурацию из /opt/grani/server-config/nginx/nginx.conf"
    cp /opt/grani/server-config/nginx/nginx.conf "$NGINX_CONF"
else
    echo "⚠️  Файл /opt/grani/server-config/nginx/nginx.conf не найден"
    echo "Добавьте location /admin вручную в файл: $NGINX_CONF"
    echo "$ADMIN_LOCATION"
    exit 1
fi

# Проверяем конфигурацию
echo "Проверка конфигурации nginx..."
if nginx -t; then
    echo "✅ Конфигурация валидна"
    
    # Перезагружаем nginx
    echo "Перезагрузка nginx..."
    if systemctl reload nginx 2>/dev/null || service nginx reload 2>/dev/null; then
        echo "✅ Nginx перезагружен"
    else
        echo "⚠️  Не удалось перезагрузить nginx автоматически"
        echo "Выполните вручную: sudo systemctl reload nginx"
    fi
else
    echo "❌ Ошибка в конфигурации nginx!"
    echo "Откатываем изменения..."
    cp "${NGINX_CONF}.backup"* "$NGINX_CONF"
    exit 1
fi

echo ""
echo "✅ Готово! Админ-панель должна быть доступна на https://granilink.com/admin"
echo ""
echo "Проверьте доступность:"
echo "  curl -I https://granilink.com/admin"




#!/bin/bash
# Сбор логов сервера для диагностики GraniVPN
# Запускать на grani-server (159.223.199.122)
# Использование: /opt/grani/scripts/collect-server-logs.sh

set -euo pipefail

LOG_DIR="/opt/grani/logs/server"
mkdir -p "$LOG_DIR"

echo "=========================================="
echo "  Сбор логов сервера GraniVPN"
echo "=========================================="
echo ""
echo "Папка: $LOG_DIR"
echo ""

# API (Docker)
echo "[1/4] Логи API (granivpn_api)..."
if docker ps --format '{{.Names}}' | grep -q granivpn_api; then
    docker logs granivpn_api --tail 500 > "$LOG_DIR/api.log" 2>&1
    echo "   ✅ api.log ($(wc -l < "$LOG_DIR/api.log") строк)"
else
    echo "   ⚠️ Контейнер granivpn_api не найден"
    echo "Контейнер granivpn_api не запущен" > "$LOG_DIR/api.log"
fi
echo ""

# Nginx access (хост или контейнер granivpn_nginx — в Docker access пишется внутрь тома/файла контейнера)
echo "[2/4] Nginx access.log..."
if [ -f /var/log/nginx/access.log ]; then
    tail -500 /var/log/nginx/access.log > "$LOG_DIR/nginx_access.log"
    echo "   ✅ nginx_access.log с хоста ($(wc -l < "$LOG_DIR/nginx_access.log") строк)"
elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qx granivpn_nginx; then
    if docker exec granivpn_nginx sh -c 'test -f /var/log/nginx/access.log' 2>/dev/null; then
        docker exec granivpn_nginx sh -c 'tail -500 /var/log/nginx/access.log' > "$LOG_DIR/nginx_access.log" 2>/dev/null || true
        echo "   ✅ nginx_access.log из контейнера granivpn_nginx ($(wc -l < "$LOG_DIR/nginx_access.log" 2>/dev/null || echo 0) строк)"
    else
        echo "   ⚠️ В контейнере granivpn_nginx нет /var/log/nginx/access.log"
        echo "Nginx access внутри контейнера недоступен" > "$LOG_DIR/nginx_access.log"
    fi
else
    echo "   ⚠️ /var/log/nginx/access.log на хосте не найден и granivpn_nginx не запущен"
    echo "Nginx access не собран" > "$LOG_DIR/nginx_access.log"
fi
echo ""

# Nginx error
echo "[3/4] Nginx error.log..."
if [ -f /var/log/nginx/error.log ]; then
    tail -200 /var/log/nginx/error.log > "$LOG_DIR/nginx_error.log"
    echo "   ✅ nginx_error.log ($(wc -l < "$LOG_DIR/nginx_error.log") строк)"
else
    echo "   ⚠️ /var/log/nginx/error.log не найден"
fi
echo ""

# Метрики (опционально, нужен ADMIN_TOKEN)
echo "[4/4] Метрики API..."
if [ -n "${ADMIN_TOKEN:-}" ]; then
    if curl -s -f -H "Authorization: Bearer $ADMIN_TOKEN" \
        https://api.granilink.com/api/admin/metrics 2>/dev/null | jq . > "$LOG_DIR/metrics.json" 2>/dev/null; then
        echo "   ✅ metrics.json"
    else
        echo "   ⚠️ Не удалось получить метрики"
    fi
else
    echo "   ⏭️ Пропущено (задайте ADMIN_TOKEN для сбора метрик)"
fi
echo ""

echo "=========================================="
echo "  ✅ Готово"
echo "=========================================="
echo ""
echo "Файлы:"
ls -la "$LOG_DIR"
echo ""
echo "💡 Добавьте /opt/grani/logs в workspace Cursor для анализа"

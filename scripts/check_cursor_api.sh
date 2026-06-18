#!/bin/bash
# Скрипт для проверки доступности API Cursor
# Использование: ./check_cursor_api.sh

echo "=== Проверка доступности API Cursor ==="
echo ""

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Функция проверки доступности
check_url() {
    local url=$1
    local name=$2
    
    echo -n "Проверка $name ($url)... "
    
    if curl -s --max-time 10 -I "$url" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Доступен${NC}"
        return 0
    else
        echo -e "${RED}✗ Недоступен${NC}"
        return 1
    fi
}

# Функция проверки DNS
check_dns() {
    local host=$1
    
    echo -n "DNS разрешение для $host... "
    
    if nslookup "$host" > /dev/null 2>&1 || host "$host" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Разрешается${NC}"
        return 0
    else
        echo -e "${RED}✗ Не разрешается${NC}"
        return 1
    fi
}

# Проверка базового интернета
echo "1. Проверка базового интернет-соединения:"
if ping -c 2 8.8.8.8 > /dev/null 2>&1; then
    echo -e "   ${GREEN}✓ Интернет доступен${NC}"
else
    echo -e "   ${RED}✗ Нет интернет-соединения${NC}"
    exit 1
fi

echo ""

# Проверка DNS
echo "2. Проверка DNS:"
check_dns "cursor.sh"
check_dns "api.cursor.sh"
check_dns "www.cursor.sh"

echo ""

# Проверка доступности сайтов
echo "3. Проверка доступности сайтов Cursor:"
check_url "https://www.cursor.sh" "Cursor главная"
check_url "https://cursor.sh" "Cursor (без www)"
check_url "https://api.cursor.sh" "Cursor API" || echo "   (API может быть недоступен снаружи)"

echo ""

# Проверка портов
echo "4. Проверка портов:"
for port in 443 80; do
    echo -n "   Порт $port... "
    if timeout 3 bash -c "echo > /dev/tcp/cursor.sh/$port" 2>/dev/null; then
        echo -e "${GREEN}✓ Открыт${NC}"
    else
        echo -e "${RED}✗ Закрыт или недоступен${NC}"
    fi
done

echo ""

# Проверка прокси
echo "5. Проверка настроек прокси:"
if [ -n "$HTTP_PROXY" ] || [ -n "$HTTPS_PROXY" ]; then
    echo -e "   ${YELLOW}⚠ Прокси настроен:${NC}"
    [ -n "$HTTP_PROXY" ] && echo "      HTTP_PROXY=$HTTP_PROXY"
    [ -n "$HTTPS_PROXY" ] && echo "      HTTPS_PROXY=$HTTPS_PROXY"
else
    echo -e "   ${GREEN}✓ Прокси не настроен${NC}"
fi

echo ""

# Итоговая сводка
echo "=== Итоговая сводка ==="
echo ""
echo "Если все проверки прошли успешно, но Cursor все равно не работает:"
echo "1. Проверьте логи Cursor на вашем устройстве"
echo "2. Проверьте настройки прокси в Cursor"
echo "3. Попробуйте перезапустить Cursor"
echo "4. Проверьте версию Cursor (обновите до последней)"
echo "5. Попробуйте с другого интернет-соединения"
echo ""

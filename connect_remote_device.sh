#!/bin/bash
# Скрипт для подключения устройства по сети с сервера
# Используйте после настройки ADB over network на локальном компьютере

set -e

# Цвета
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

export PATH=$PATH:/opt/android-sdk/platform-tools

echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}  Подключение устройства по сети${NC}"
echo -e "${BLUE}==========================================${NC}"
echo ""

# Парсинг аргументов
DEVICE_IP=""
PORT=5555

if [ $# -eq 0 ]; then
    echo "Использование: $0 <IP_ADDRESS> [PORT]"
    echo ""
    echo "Пример:"
    echo "  $0 192.168.1.100"
    echo "  $0 192.168.1.100 5555"
    echo ""
    echo "Если IP адрес неизвестен, используйте:"
    echo "  $0 --scan"
    exit 1
fi

if [ "$1" = "--scan" ]; then
    echo -e "${BLUE}Сканирование сети для поиска устройств ADB...${NC}"
    echo "Это может занять некоторое время..."
    echo ""
    
    # Получаем локальный IP адрес сервера
    LOCAL_IP=$(hostname -I | awk '{print $1}' | cut -d. -f1-3)
    
    if [ -z "$LOCAL_IP" ]; then
        echo -e "${RED}❌ Не удалось определить локальную сеть${NC}"
        exit 1
    fi
    
    echo "Сканирование сети: ${LOCAL_IP}.0/24"
    echo ""
    
    FOUND=0
    for i in {1..254}; do
        IP="${LOCAL_IP}.${i}"
        echo -n "Проверка $IP... "
        
        if timeout 1 adb connect "$IP:5555" 2>&1 | grep -q "connected"; then
            echo -e "${GREEN}✅ Найдено!${NC}"
            DEVICE_IP="$IP"
            FOUND=1
            break
        else
            adb disconnect "$IP:5555" 2>/dev/null || true
            echo "нет"
        fi
    done
    
    if [ $FOUND -eq 0 ]; then
        echo ""
        echo -e "${RED}❌ Устройства не найдены${NC}"
        echo ""
        echo "Убедитесь, что:"
        echo "  1. ADB over network настроен на локальном компьютере"
        echo "  2. Устройство и сервер в одной сети"
        echo "  3. Устройство подключено к Wi-Fi"
        exit 1
    fi
else
    DEVICE_IP="$1"
    if [ -n "$2" ]; then
        PORT="$2"
    fi
fi

# Проверка IP адреса
if [ -z "$DEVICE_IP" ]; then
    echo -e "${RED}❌ IP адрес не указан${NC}"
    exit 1
fi

echo -e "${BLUE}Подключение к устройству: ${DEVICE_IP}:${PORT}...${NC}"

# Отключаем предыдущее подключение если есть
adb disconnect "${DEVICE_IP}:${PORT}" 2>/dev/null || true

# Подключаемся
CONNECT_RESULT=$(adb connect "${DEVICE_IP}:${PORT}" 2>&1)

if echo "$CONNECT_RESULT" | grep -q "connected"; then
    echo -e "${GREEN}✅ Успешно подключено: ${DEVICE_IP}:${PORT}${NC}"
elif echo "$CONNECT_RESULT" | grep -q "already connected"; then
    echo -e "${GREEN}✅ Уже подключено: ${DEVICE_IP}:${PORT}${NC}"
else
    echo -e "${RED}❌ Не удалось подключиться${NC}"
    echo "$CONNECT_RESULT"
    echo ""
    echo "Проверьте:"
    echo "  1. Устройство и сервер в одной сети"
    echo "  2. ADB over network настроен на локальном компьютере"
    echo "  3. IP адрес правильный"
    echo "  4. Firewall не блокирует порт $PORT"
    exit 1
fi

echo ""
echo "Проверка подключения:"
adb devices
echo ""

DEVICE_COUNT=$(adb devices | grep -v "List" | grep "device$" | wc -l)
if [ "$DEVICE_COUNT" -gt 0 ]; then
    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}✅ Устройство готово к использованию!${NC}"
    echo -e "${GREEN}==========================================${NC}"
    echo ""
    echo -e "${BLUE}Теперь можно запустить:${NC}"
    echo "  /opt/grani/dev_run.sh"
    echo ""
    echo -e "${BLUE}Для отключения:${NC}"
    echo "  adb disconnect ${DEVICE_IP}:${PORT}"
else
    echo -e "${RED}❌ Устройство не найдено после подключения${NC}"
    exit 1
fi






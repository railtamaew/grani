#!/bin/bash

# Скрипт для настройки ADB на вашем локальном компьютере
# Использование: ./setup_adb_remote_client.sh [--device-ip IP] [--server SERVER]

set -euo pipefail

DEVICE_IP=""
SERVER="granilink.com"
SERVER_USER="root"
ADB_PORT=5555
SSH_TUNNEL_PORT=5555

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
    case $1 in
        --device-ip)
            DEVICE_IP="$2"
            shift 2
            ;;
        --server)
            SERVER="$2"
            shift 2
            ;;
        --server-user)
            SERVER_USER="$2"
            shift 2
            ;;
        *)
            echo "❌ Неизвестный параметр: $1"
            exit 1
            ;;
    esac
done

echo "=========================================="
echo "  Настройка ADB для удаленного доступа"
echo "=========================================="
echo ""
echo "Сервер: $SERVER_USER@$SERVER"
echo ""

# Проверка ADB
if ! command -v adb &> /dev/null; then
    echo "❌ Ошибка: ADB не установлен"
    echo "   Установите Android SDK Platform Tools:"
    echo "   https://developer.android.com/studio/releases/platform-tools"
    exit 1
fi

echo "✅ ADB найден: $(which adb)"
echo ""

# Проверка подключенных устройств
echo "[1/5] Проверка подключенных устройств..."
DEVICES=$(adb devices | grep -v "List" | grep "device" | awk '{print $1}' || echo "")

if [ -z "$DEVICES" ]; then
    echo "   ❌ Устройства не найдены"
    echo ""
    echo "💡 Инструкции:"
    echo "   1. Подключите устройство по USB"
    echo "   2. Включите 'Отладка по USB' в настройках разработчика"
    echo "   3. Разрешите отладку на устройстве"
    echo "   4. Запустите скрипт снова"
    exit 1
fi

DEVICE=$(echo "$DEVICES" | head -1)
echo "   ✅ Устройство найдено: $DEVICE"
echo ""

# Получение IP адреса устройства
echo "[2/5] Получение IP адреса устройства..."
if [ -z "$DEVICE_IP" ]; then
    # Пробуем получить IP через WiFi
    DEVICE_IP=$(adb -s "$DEVICE" shell "getprop dhcp.wlan0.ipaddress" 2>/dev/null | tr -d '\r\n' || echo "")
    
    if [ -z "$DEVICE_IP" ]; then
        # Альтернативный способ
        DEVICE_IP=$(adb -s "$DEVICE" shell "ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1" | tr -d '\r\n' || echo "")
    fi
    
    if [ -z "$DEVICE_IP" ]; then
        echo "   ⚠️  Не удалось получить IP адрес автоматически"
        echo ""
        echo "💡 Введите IP адрес устройства вручную:"
        read -p "   IP адрес: " DEVICE_IP
    fi
fi

if [ -z "$DEVICE_IP" ]; then
    echo "   ❌ IP адрес не указан"
    exit 1
fi

echo "   ✅ IP адрес: $DEVICE_IP"
echo ""

# Включение TCP/IP режима
echo "[3/5] Включение TCP/IP режима ADB..."
adb -s "$DEVICE" tcpip "$ADB_PORT" > /dev/null 2>&1
sleep 2
echo "   ✅ TCP/IP режим включен (порт $ADB_PORT)"
echo ""

# Подключение по сети
echo "[4/5] Подключение к устройству по сети..."
adb connect "${DEVICE_IP}:${ADB_PORT}" > /dev/null 2>&1
sleep 1

if adb devices | grep -q "${DEVICE_IP}:${ADB_PORT}"; then
    echo "   ✅ Устройство подключено по сети"
    echo "   Теперь можно отключить USB кабель"
else
    echo "   ⚠️  Не удалось подключиться по сети"
    echo "   Убедитесь, что устройство и компьютер в одной Wi-Fi сети"
    echo "   IP адрес: $DEVICE_IP"
fi
echo ""

# Создание SSH туннеля
echo "[5/5] Создание SSH туннеля к серверу..."
echo "   Сервер: $SERVER_USER@$SERVER"
echo "   Локальный порт: $SSH_TUNNEL_PORT"
echo "   Удаленный порт: $SSH_TUNNEL_PORT"
echo ""

# Проверка SSH подключения
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$SERVER_USER@$SERVER" "echo 'Connected'" > /dev/null 2>&1; then
    echo "   ⚠️  Не удалось подключиться к серверу по SSH"
    echo ""
    echo "💡 Создайте SSH туннель вручную:"
    echo "   ssh -R ${SSH_TUNNEL_PORT}:localhost:${SSH_TUNNEL_PORT} $SERVER_USER@$SERVER -N"
    echo ""
    echo "   Оставьте это окно открытым и выполните на сервере:"
    echo "   adb connect localhost:$SSH_TUNNEL_PORT"
    exit 0
fi

# Создаем SSH туннель в фоне
SSH_TUNNEL_PID=$(ssh -f -N -R "${SSH_TUNNEL_PORT}:localhost:${SSH_TUNNEL_PORT}" "$SERVER_USER@$SERVER" 2>&1 | grep -oP '\[?\d+\]?' | head -1 || echo "")

if [ -n "$SSH_TUNNEL_PID" ]; then
    echo "   ✅ SSH туннель создан (PID: $SSH_TUNNEL_PID)"
    echo "$SSH_TUNNEL_PID" > /tmp/adb_tunnel_${SSH_TUNNEL_PORT}.pid
else
    # Проверяем, может туннель уже работает
    if ssh "$SERVER_USER@$SERVER" "netstat -ln 2>/dev/null | grep -q ':${SSH_TUNNEL_PORT}'" 2>/dev/null; then
        echo "   ✅ SSH туннель уже активен"
    else
        echo "   ⚠️  Не удалось создать SSH туннель автоматически"
        echo ""
        echo "💡 Создайте SSH туннель вручную:"
        echo "   ssh -R ${SSH_TUNNEL_PORT}:localhost:${SSH_TUNNEL_PORT} $SERVER_USER@$SERVER -N"
    fi
fi
echo ""

# Итоги
echo "=========================================="
echo "  ✅ Настройка завершена!"
echo "=========================================="
echo ""
echo "📱 Устройство:"
echo "   IP: $DEVICE_IP"
echo "   Порт: $ADB_PORT"
echo ""
echo "🔗 SSH туннель:"
echo "   Сервер: $SERVER_USER@$SERVER"
echo "   Порт: $SSH_TUNNEL_PORT"
echo ""
echo "📝 На сервере выполните:"
echo "   adb connect localhost:$SSH_TUNNEL_PORT"
echo "   adb devices"
echo ""
echo "🛑 Для остановки туннеля:"
if [ -f "/tmp/adb_tunnel_${SSH_TUNNEL_PORT}.pid" ]; then
    TUNNEL_PID=$(cat "/tmp/adb_tunnel_${SSH_TUNNEL_PORT}.pid")
    echo "   kill $TUNNEL_PID"
fi
echo "   или"
echo "   ssh $SERVER_USER@$SERVER 'pkill -f \"ssh.*${SSH_TUNNEL_PORT}\"'"
echo ""

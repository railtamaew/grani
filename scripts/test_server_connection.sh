#!/bin/bash

# Скрипт для тестирования подключения к VPN серверу
# Использование: ./test_server_connection.sh [server_ip] [username] [password]
# Пароль: 3-й аргумент или переменная окружения SSH_PASSWORD

SERVER_IP="${1:-45.12.132.94}"
USERNAME="${2:-root}"
PASSWORD="${3:-${SSH_PASSWORD}}"
if [ -z "$PASSWORD" ]; then
  echo "❌ Задайте пароль: 3-й аргумент или SSH_PASSWORD"
  exit 1
fi

echo "=========================================="
echo "Тестирование подключения к VPN серверу"
echo "=========================================="
echo "IP: $SERVER_IP"
echo "Пользователь: $USERNAME"
echo ""

# Функция для выполнения команды через SSH с паролем
ssh_execute() {
    local command="$1"
    sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USERNAME@$SERVER_IP" "$command"
}

# Функция для проверки наличия команды
check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &> /dev/null; then
        echo "❌ Команда $cmd не найдена. Установите: sudo apt-get install $cmd"
        return 1
    fi
    return 0
}

# Проверка необходимых команд
echo "1. Проверка необходимых команд..."
if ! check_command "sshpass"; then
    echo "Установка sshpass..."
    sudo apt-get update && sudo apt-get install -y sshpass
fi

# Тест SSH подключения
echo ""
echo "2. Тестирование SSH подключения..."
if ssh_execute "echo 'SSH подключение успешно'"; then
    echo "✅ SSH подключение работает"
else
    echo "❌ Ошибка SSH подключения"
    exit 1
fi

# Проверка наличия WireGuard
echo ""
echo "3. Проверка наличия WireGuard..."
if ssh_execute "which wg" > /dev/null 2>&1; then
    echo "✅ WireGuard установлен"
    WG_VERSION=$(ssh_execute "wg --version" 2>/dev/null | head -n1)
    echo "   Версия: $WG_VERSION"
else
    echo "⚠️  WireGuard не установлен"
    echo ""
    echo "4. Установка WireGuard..."
    echo "   Выполняется: apt-get update && apt-get install -y wireguard wireguard-tools"
    if ssh_execute "apt-get update && apt-get install -y wireguard wireguard-tools"; then
        echo "✅ WireGuard установлен"
    else
        echo "❌ Ошибка установки WireGuard"
        exit 1
    fi
fi

# Проверка модуля WireGuard
echo ""
echo "5. Проверка модуля WireGuard..."
if ssh_execute "lsmod | grep wireguard" > /dev/null 2>&1; then
    echo "✅ Модуль WireGuard загружен"
else
    echo "⚠️  Модуль WireGuard не загружен"
    echo "   Загрузка модуля..."
    ssh_execute "modprobe wireguard"
    if ssh_execute "lsmod | grep wireguard" > /dev/null 2>&1; then
        echo "✅ Модуль WireGuard загружен"
        # Добавляем в автозагрузку
        ssh_execute "echo 'wireguard' >> /etc/modules-load.d/wireguard.conf"
    else
        echo "❌ Не удалось загрузить модуль WireGuard"
    fi
fi

# Проверка конфигурации WireGuard
echo ""
echo "6. Проверка конфигурации WireGuard..."
if ssh_execute "test -f /etc/wireguard/wg0.conf"; then
    echo "✅ Конфигурация WireGuard найдена"
    echo "   Проверка содержимого..."
    ssh_execute "cat /etc/wireguard/wg0.conf" | head -n 10
else
    echo "⚠️  Конфигурация WireGuard не найдена"
    echo "   Будет создана при первом подключении"
fi

# Проверка статуса WireGuard
echo ""
echo "7. Проверка статуса WireGuard интерфейса..."
WG_STATUS=$(ssh_execute "wg show 2>/dev/null || echo 'not_running'")
if [ "$WG_STATUS" != "not_running" ]; then
    echo "✅ WireGuard интерфейс активен"
    echo "$WG_STATUS" | head -n 5
else
    echo "⚠️  WireGuard интерфейс не запущен"
fi

# Проверка сетевых интерфейсов
echo ""
echo "8. Проверка сетевых интерфейсов..."
INTERFACES=$(ssh_execute "ip link show | grep -E '^[0-9]+:' | awk '{print \$2}' | sed 's/://'")
echo "   Найденные интерфейсы:"
echo "$INTERFACES" | while read iface; do
    echo "   - $iface"
done

# Проверка портов
echo ""
echo "9. Проверка открытых портов..."
OPEN_PORTS=$(ssh_execute "netstat -tuln 2>/dev/null | grep LISTEN | awk '{print \$4}' | cut -d: -f2 | sort -u")
echo "   Открытые порты:"
echo "$OPEN_PORTS" | while read port; do
    echo "   - $port"
done

# Итоговая информация
echo ""
echo "=========================================="
echo "Результаты тестирования"
echo "=========================================="
echo "✅ SSH подключение: Работает"
if ssh_execute "which wg" > /dev/null 2>&1; then
    echo "✅ WireGuard: Установлен"
else
    echo "❌ WireGuard: Не установлен"
fi
echo ""
echo "Сервер готов к настройке VPN подключений"
echo "=========================================="







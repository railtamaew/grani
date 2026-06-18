#!/bin/bash

# Скрипт для проверки настройки сервера перед запуском тестов
# Проверяет:
# 1. WireGuard пир клиента добавлен на сервере
# 2. UUID для XRay добавлен на сервере

set -e

SERVER_IP="${SERVER_IP:-45.12.132.94}"
SERVER_USER="${SERVER_USER:-root}"
SERVER_PASSWORD="${SERVER_PASSWORD:-$SSH_PASSWORD}"
if [ -z "$SERVER_PASSWORD" ]; then
  echo "❌ Задайте SSH_PASSWORD или SERVER_PASSWORD"
  exit 1
fi

# Ключи для проверки
CLIENT_PUBLIC_KEY="TVg3PioAwVBCbPxC9I0vRGI8YokqnMx7NlBDoPZrgCo="
TEST_UUID="691022bf-14cf-4ec3-8649-c49988f8578f"

echo "=========================================="
echo "  Проверка настройки сервера"
echo "=========================================="
echo ""
echo "Сервер: $SERVER_USER@$SERVER_IP"
echo ""

# Проверка SSH подключения
echo "🔌 Проверка SSH подключения..."
if ! sshpass -p "$SERVER_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$SERVER_USER@$SERVER_IP" "echo 'Connected'" > /dev/null 2>&1; then
    echo "❌ Ошибка: Не удалось подключиться к серверу"
    echo "   Проверьте доступность сервера: ping $SERVER_IP"
    exit 1
fi
echo "✅ SSH подключение работает"
echo ""

# Проверка WireGuard пира
echo "🔑 Проверка WireGuard пира..."
WG_OUTPUT=$(sshpass -p "$SERVER_PASSWORD" ssh -o StrictHostKeyChecking=no "$SERVER_USER@$SERVER_IP" "wg show wg0 2>&1" || echo "")

if echo "$WG_OUTPUT" | grep -q "$CLIENT_PUBLIC_KEY"; then
    echo "✅ WireGuard пир найден на сервере"
    echo "   Публичный ключ: $CLIENT_PUBLIC_KEY"
    WIREGUARD_OK=true
else
    echo "❌ WireGuard пир НЕ найден на сервере"
    echo "   Ожидаемый публичный ключ: $CLIENT_PUBLIC_KEY"
    echo ""
    echo "   Текущие пиры на сервере:"
    echo "$WG_OUTPUT" | grep -E "peer:|PublicKey" | head -10 || echo "   (нет пиров или WireGuard не запущен)"
    WIREGUARD_OK=false
fi
echo ""

# Проверка XRay UUID
echo "🔍 Проверка XRay UUID..."
XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"

# Проверяем наличие UUID в конфигурации XRay
XRAY_CHECK=$(sshpass -p "$SERVER_PASSWORD" ssh -o StrictHostKeyChecking=no "$SERVER_USER@$SERVER_IP" "
    if [ -f $XRAY_CONFIG_PATH ]; then
        if grep -q '$TEST_UUID' $XRAY_CONFIG_PATH; then
            echo 'FOUND'
        else
            echo 'NOT_FOUND'
        fi
    else
        echo 'NO_CONFIG'
    fi
" 2>&1)

if echo "$XRAY_CHECK" | grep -q "FOUND"; then
    echo "✅ UUID найден в конфигурации XRay"
    echo "   UUID: $TEST_UUID"
    XRAY_OK=true
elif echo "$XRAY_CHECK" | grep -q "NO_CONFIG"; then
    echo "⚠️  Конфигурация XRay не найдена: $XRAY_CONFIG_PATH"
    echo "   UUID не может быть проверен"
    XRAY_OK=false
else
    echo "❌ UUID НЕ найден в конфигурации XRay"
    echo "   Ожидаемый UUID: $TEST_UUID"
    XRAY_OK=false
fi
echo ""

# Итоги
echo "=========================================="
echo "  Итоги проверки"
echo "=========================================="
echo ""

if [ "$WIREGUARD_OK" = true ] && [ "$XRAY_OK" = true ]; then
    echo "✅ Все проверки пройдены!"
    echo "   - WireGuard пир: ✅"
    echo "   - XRay UUID: ✅"
    echo ""
    echo "🚀 Можно запускать тесты"
    exit 0
elif [ "$WIREGUARD_OK" = true ]; then
    echo "⚠️  Частично готово:"
    echo "   - WireGuard пир: ✅"
    echo "   - XRay UUID: ❌"
    echo ""
    echo "💡 Можно запускать тесты только для WireGuard"
    exit 2
elif [ "$XRAY_OK" = true ]; then
    echo "⚠️  Частично готово:"
    echo "   - WireGuard пир: ❌"
    echo "   - XRay UUID: ✅"
    echo ""
    echo "💡 Можно запускать тесты только для Sing-box"
    exit 3
else
    echo "❌ Сервер не готов:"
    echo "   - WireGuard пир: ❌"
    echo "   - XRay UUID: ❌"
    echo ""
    echo "💡 Необходимо настроить сервер перед запуском тестов"
    exit 1
fi

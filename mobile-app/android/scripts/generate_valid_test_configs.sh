#!/bin/bash

# Скрипт для генерации валидных тестовых конфигураций с реальными ключами
# Использование: ./scripts/generate_valid_test_configs.sh [--output-dir DIR]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${PROJECT_DIR}/test_configs"

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
    case $1 in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        *)
            echo "❌ Неизвестный параметр: $1"
            exit 1
            ;;
    esac
done

# Создаем директорию для конфигов
mkdir -p "$OUTPUT_DIR"

echo "🔧 Генерация валидных тестовых конфигураций..."
echo "📁 Выходная директория: $OUTPUT_DIR"
echo ""

# Проверка наличия WireGuard tools
if ! command -v wg &> /dev/null; then
    echo "❌ Ошибка: WireGuard tools не установлены"
    echo "   Установите: apt-get install wireguard wireguard-tools"
    exit 1
fi

# ========== WireGuard конфигурация ==========

echo "🔑 Использование реального WireGuard сервера..."

# Реальные данные сервера
REAL_SERVER_IP="45.12.132.94"
REAL_SERVER_PORT="51820"
REAL_SERVER_PUBLIC_KEY="1f9Euwg9rNI7A2BnsTzjyKdxyo2j7kRbYpyrIKpT6Fc="

# Используем реальный приватный ключ клиента из существующего конфига
# Если файл существует, используем его, иначе генерируем новый
if [ -f "/opt/grani/wg0.conf" ]; then
    # Извлекаем приватный ключ, убирая пробелы и переносы строк
    CLIENT_PRIVATE_KEY=$(grep "^PrivateKey" /opt/grani/wg0.conf | sed 's/PrivateKey[[:space:]]*=[[:space:]]*//' | tr -d ' \n\r')
    if [ -z "$CLIENT_PRIVATE_KEY" ] || [ ${#CLIENT_PRIVATE_KEY} -lt 40 ]; then
        echo "⚠️  Не удалось извлечь валидный ключ из /opt/grani/wg0.conf, генерируем новый"
        CLIENT_PRIVATE_KEY=$(wg genkey)
    else
        echo "✅ Использован приватный ключ из /opt/grani/wg0.conf"
    fi
else
    CLIENT_PRIVATE_KEY=$(wg genkey)
    echo "✅ Сгенерирован новый приватный ключ клиента"
fi

CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)

echo "✅ Данные сервера:"
echo "   Server IP: $REAL_SERVER_IP"
echo "   Server Port: $REAL_SERVER_PORT"
echo "   Server Public Key: ${REAL_SERVER_PUBLIC_KEY:0:20}..."
echo "   Client Private Key: ${CLIENT_PRIVATE_KEY:0:20}..."
echo "   Client Public Key: ${CLIENT_PUBLIC_KEY:0:20}..."
echo ""

# Создаем валидную WireGuard конфигурацию с реальным сервером
cat > "$OUTPUT_DIR/wireguard_valid.conf" << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = 10.0.0.2/32
DNS = 8.8.8.8, 8.8.4.4
MTU = 1420

[Peer]
PublicKey = $REAL_SERVER_PUBLIC_KEY
Endpoint = $REAL_SERVER_IP:$REAL_SERVER_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

echo "✅ Создан wireguard_valid.conf с реальным сервером"
echo "   ✅ Endpoint = $REAL_SERVER_IP:$REAL_SERVER_PORT"
echo "   ✅ Используется реальный публичный ключ сервера"
echo ""

# Сохраняем информацию о сервере для справки
cat > "$OUTPUT_DIR/wireguard_server_info.txt" << EOF
# Информация о реальном WireGuard сервере

[Server]
IP = $REAL_SERVER_IP
Port = $REAL_SERVER_PORT
PublicKey = $REAL_SERVER_PUBLIC_KEY

[Client]
PrivateKey = $CLIENT_PRIVATE_KEY
PublicKey = $CLIENT_PUBLIC_KEY
Address = 10.0.0.2/32

# Важно: Пир клиента должен быть добавлен на сервере
# Публичный ключ клиента: $CLIENT_PUBLIC_KEY
# IP клиента: 10.0.0.2/32
EOF

echo "✅ Сохранена информация о сервере в wireguard_server_info.txt"
echo ""

# ========== Sing-box конфигурация ==========

echo "📝 Создание валидной sing-box конфигурации..."

# Минимальная валидная конфигурация sing-box
# Эта конфигурация создаст TUN интерфейс, что достаточно для тестирования
cat > "$OUTPUT_DIR/singbox_valid.json" << 'EOF'
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "inet4_address": "10.0.0.2/30",
      "mtu": 1420,
      "stack": "system",
      "sniff": true,
      "auto_route": true,
      "strict_route": false
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "dns": {
    "servers": [
      {
        "address": "8.8.8.8"
      },
      {
        "address": "8.8.4.4"
      }
    ]
  }
}
EOF

echo "✅ Создан singbox_valid.json"
echo "   ⚠️  Примечание: Использует 'direct' outbound (локальное подключение)"
echo "   Для реального VPN подключения добавьте валидный outbound (vless/vmess/etc)"
echo ""

# ========== Sing-box конфигурация с реальным сервером ==========

echo "📝 Создание sing-box конфигурации с реальным сервером..."

# Реальные данные XRay сервера
REAL_XRAY_SERVER_IP="45.12.132.94"
REAL_XRAY_SERVER_PORT="4443"

# REALITY параметры (из тестов)
REALITY_PUBLIC_KEY="Pyqln2OpBGGAJVXweJusMJAqzuqqH675fqF8Bdl3kGY"
REALITY_SHORT_ID="822c3e48"
REALITY_SNI="www.google.com"

# UUID для тестирования (можно использовать тестовый UUID)
# В реальных тестах UUID должен быть добавлен на сервере через API
TEST_UUID="691022bf-14cf-4ec3-8649-c49988f8578f"

# Конфигурация с REALITY (рекомендуется для обхода блокировок)
cat > "$OUTPUT_DIR/singbox_reality_valid.json" << EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "inet4_address": "10.0.0.2/30",
      "mtu": 1420,
      "stack": "system",
      "sniff": true,
      "auto_route": true,
      "strict_route": false
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-out",
      "server": "$REAL_XRAY_SERVER_IP",
      "server_port": $REAL_XRAY_SERVER_PORT,
      "uuid": "$TEST_UUID",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SNI",
        "reality": {
          "public_key": "$REALITY_PUBLIC_KEY",
          "short_id": "$REALITY_SHORT_ID"
        }
      }
    }
  ],
  "dns": {
    "servers": [
      {
        "address": "8.8.8.8"
      },
      {
        "address": "8.8.4.4"
      }
    ]
  }
}
EOF

echo "✅ Создан singbox_reality_valid.json с реальным сервером"
echo "   ✅ Server: $REAL_XRAY_SERVER_IP:$REAL_XRAY_SERVER_PORT"
echo "   ✅ Protocol: VLESS + REALITY"
echo "   ⚠️  Примечание: UUID должен быть добавлен на сервере через API"
echo ""

# Конфигурация с простым VLESS (без REALITY)
cat > "$OUTPUT_DIR/singbox_vless_valid.json" << EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "inet4_address": "10.0.0.2/30",
      "mtu": 1420,
      "stack": "system",
      "sniff": true,
      "auto_route": true,
      "strict_route": false
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-out",
      "server": "$REAL_XRAY_SERVER_IP",
      "server_port": $REAL_XRAY_SERVER_PORT,
      "uuid": "$TEST_UUID",
      "flow": ""
    }
  ],
  "dns": {
    "servers": [
      {
        "address": "8.8.8.8"
      },
      {
        "address": "8.8.4.4"
      }
    ]
  }
}
EOF

echo "✅ Создан singbox_vless_valid.json с реальным сервером"
echo "   ✅ Server: $REAL_XRAY_SERVER_IP:$REAL_XRAY_SERVER_PORT"
echo "   ✅ Protocol: VLESS"
echo "   ⚠️  Примечание: UUID должен быть добавлен на сервере через API"
echo ""

# ========== Информационный файл ==========

cat > "$OUTPUT_DIR/README_VALID_CONFIGS.md" << EOF
# Валидные тестовые конфигурации

## WireGuard

**Файл:** \`wireguard_valid.conf\`

✅ Содержит валидные WireGuard ключи (сгенерированы автоматически)
✅ Готова к использованию в тестах
⚠️  Endpoint = 127.0.0.1:51820 (для тестирования на localhost)

**Для реального подключения:**
1. Замените \`Endpoint\` на IP реального WireGuard сервера
2. Убедитесь, что сервер использует публичный ключ из \`wireguard_server_keys.txt\`

## Sing-box

### Минимальная конфигурация

**Файл:** \`singbox_valid.json\`

✅ Создает TUN интерфейс
✅ Использует 'direct' outbound (локальное подключение)
✅ Готова к использованию в тестах для проверки создания VPN интерфейса

**Ограничения:**
- Не создает реальное VPN подключение (только интерфейс)
- Подходит для тестирования парсинга конфигурации и создания интерфейса

### Конфигурация с VLESS

**Файл:** \`singbox_vless_valid.json\`

⚠️  Требует замены:
- \`server\`: IP или домен реального сервера
- \`uuid\`: Валидный UUID для VLESS
- \`server_name\`: Доменное имя для TLS

## Использование в тестах

### Firebase Test Lab

\`\`\`bash
cd /opt/grani/mobile-app/android
./scripts/run_firebase_tests.sh \\
  --singbox-config test_configs/singbox_valid.json \\
  --wireguard-config test_configs/wireguard_valid.conf \\
  --device-model Pixel2.arm \\
  --device-version 30
\`\`\`

### Локальные тесты

\`\`\`bash
cd /opt/grani/mobile-app/android
./gradlew connectedDebugAndroidTest \\
  -Pandroid.testInstrumentationRunnerArguments.singbox_config_b64=\$(base64 -w 0 < test_configs/singbox_valid.json) \\
  -Pandroid.testInstrumentationRunnerArguments.wireguard_config_b64=\$(base64 -w 0 < test_configs/wireguard_valid.conf)
\`\`\`

## Генерация новых ключей

Если нужно сгенерировать новые ключи:

\`\`\`bash
./scripts/generate_valid_test_configs.sh
\`\`\`

Это перезапишет существующие конфигурации новыми ключами.
EOF

echo "✅ Создан README_VALID_CONFIGS.md"
echo ""

# ========== Итоги ==========

echo "=========================================="
echo "✅ Генерация завершена!"
echo "=========================================="
echo ""
echo "📝 Созданные файлы:"
echo "   ✅ wireguard_valid.conf - валидная WireGuard конфигурация"
echo "   ✅ wireguard_server_keys.txt - ключи сервера (для справки)"
echo "   ✅ singbox_valid.json - минимальная sing-box конфигурация"
echo "   ✅ singbox_vless_valid.json - пример с VLESS"
echo "   ✅ README_VALID_CONFIGS.md - документация"
echo ""
echo "💡 Использование:"
echo "   ./scripts/run_firebase_tests.sh \\"
echo "     --singbox-config test_configs/singbox_reality_valid.json \\"
echo "     --wireguard-config test_configs/wireguard_valid.conf"
echo ""
echo "✅ Реальные серверы:"
echo "   - WireGuard: 45.12.132.94:51820"
echo "   - XRay (VLESS/REALITY): 45.12.132.94:4443"
echo ""
echo "⚠️  Важно:"
echo "   - WireGuard: убедитесь, что пир клиента добавлен на сервере"
echo "   - Sing-box: убедитесь, что UUID добавлен на сервере через API"
echo ""

#!/bin/bash

# Утилита для генерации тестовых конфигов (sing-box и WireGuard)
# Использование: ./scripts/generate_test_configs.sh [--output-dir DIR]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$PROJECT_DIR/test_configs}"

# Создаем директорию для конфигов
mkdir -p "$OUTPUT_DIR"

echo "🔧 Генерация тестовых конфигураций..."
echo "📁 Выходная директория: $OUTPUT_DIR"
echo ""

# Генерация минимального sing-box конфига (для тестирования)
cat > "$OUTPUT_DIR/singbox_minimal.json" << 'EOF'
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
      "sniff": true
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

echo "✅ Создан singbox_minimal.json"

# Генерация примера sing-box конфига с VLESS
cat > "$OUTPUT_DIR/singbox_vless_example.json" << 'EOF'
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
      "sniff": true
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-out",
      "server": "example.com",
      "server_port": 443,
      "uuid": "00000000-0000-0000-0000-000000000000",
      "flow": "",
      "tls": {
        "enabled": true,
        "server_name": "example.com",
        "insecure": false
      }
    }
  ]
}
EOF

echo "✅ Создан singbox_vless_example.json"

# Генерация примера WireGuard конфига
cat > "$OUTPUT_DIR/wireguard_example.conf" << 'EOF'
[Interface]
PrivateKey = YOUR_PRIVATE_KEY_HERE
Address = 10.0.0.2/32
DNS = 8.8.8.8, 8.8.4.4
MTU = 1420

[Peer]
PublicKey = SERVER_PUBLIC_KEY_HERE
Endpoint = example.com:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

echo "✅ Создан wireguard_example.conf"

# Генерация скрипта для кодирования конфигов в base64
cat > "$OUTPUT_DIR/encode_configs.sh" << 'EOF'
#!/bin/bash
# Скрипт для кодирования конфигов в base64

echo "🔐 Кодирование конфигураций в base64..."
echo ""

if [ -f "singbox_minimal.json" ]; then
    echo "singbox_minimal.json (base64):"
    base64 -w 0 < singbox_minimal.json
    echo ""
    echo ""
fi

if [ -f "singbox_vless_example.json" ]; then
    echo "singbox_vless_example.json (base64):"
    base64 -w 0 < singbox_vless_example.json
    echo ""
    echo ""
fi

if [ -f "wireguard_example.conf" ]; then
    echo "wireguard_example.conf (base64):"
    base64 -w 0 < wireguard_example.conf
    echo ""
    echo ""
fi
EOF

chmod +x "$OUTPUT_DIR/encode_configs.sh"
echo "✅ Создан encode_configs.sh"

echo ""
echo "✅ Генерация завершена!"
echo ""
echo "📝 Созданные файлы:"
echo "   - singbox_minimal.json (минимальный конфиг для тестирования)"
echo "   - singbox_vless_example.json (пример с VLESS)"
echo "   - wireguard_example.conf (пример WireGuard конфига)"
echo "   - encode_configs.sh (скрипт для кодирования в base64)"
echo ""
echo "💡 Использование:"
echo "   1. Отредактируйте конфиги, заменив placeholder значения"
echo "   2. Запустите: cd $OUTPUT_DIR && ./encode_configs.sh"
echo "   3. Используйте base64 строки в тестах"
echo ""

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

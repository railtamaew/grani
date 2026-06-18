#!/bin/bash
# Тестирование sing-box конфигураций через Docker
# Использование: ./scripts/test_singbox_docker.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🐳 Тестирование sing-box конфигураций через Docker..."
echo ""

# Проверяем наличие Docker
if ! command -v docker &> /dev/null; then
    echo "❌ Docker не найден. Установите Docker для использования этого скрипта."
    exit 1
fi

# Генерируем тестовую конфигурацию
TEMP_CONFIG=$(mktemp)
python3 "$SCRIPT_DIR/test_singbox_config.py" --generate --output "$TEMP_CONFIG"

if [ ! -f "$TEMP_CONFIG" ]; then
    echo "❌ Не удалось сгенерировать конфигурацию"
    exit 1
fi

echo "📋 Сгенерированная конфигурация:"
cat "$TEMP_CONFIG"
echo ""

# Валидируем через Docker
echo "🔍 Валидация конфигурации через sing-box (Docker)..."
if docker run --rm -i \
    -v "$TEMP_CONFIG:/config.json:ro" \
    ghcr.io/sagernet/sing-box:latest \
    sing-box check -c /config.json 2>&1; then
    echo ""
    echo "✅ Конфигурация валидна!"
    rm -f "$TEMP_CONFIG"
    exit 0
else
    echo ""
    echo "❌ Конфигурация невалидна"
    rm -f "$TEMP_CONFIG"
    exit 1
fi

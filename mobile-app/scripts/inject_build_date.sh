#!/bin/bash
# Скрипт для инжекции даты и времени сборки в app_config.dart

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/lib/config/app_config.dart"

# Получаем текущую дату и время
BUILD_DATE=$(date '+%Y-%m-%d %H:%M')

echo "🔧 Инжекция даты сборки: $BUILD_DATE"

# Проверяем существование файла
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Файл $CONFIG_FILE не найден!"
    exit 1
fi

# Заменяем дату сборки в файле
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    sed -i '' "s/static String buildDate = '.*';/static String buildDate = '$BUILD_DATE';/" "$CONFIG_FILE"
else
    # Linux
    sed -i "s/static String buildDate = '.*';/static String buildDate = '$BUILD_DATE';/" "$CONFIG_FILE"
fi

echo "✅ Дата сборки обновлена в $CONFIG_FILE"
echo "   Новая дата: $BUILD_DATE"




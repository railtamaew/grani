#!/bin/bash
# Скрипт для отключения звуковых уведомлений Cursor
# ВЫПОЛНИТЕ ЭТОТ СКРИПТ НА ВАШЕЙ ЛОКАЛЬНОЙ МАШИНЕ (не на сервере)

echo "🔇 Отключение звуковых уведомлений Cursor..."

# Определяем путь к настройкам в зависимости от ОС
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    SETTINGS_FILE="$HOME/.config/Cursor/User/settings.json"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    SETTINGS_FILE="$HOME/Library/Application Support/Cursor/User/settings.json"
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
    SETTINGS_FILE="$APPDATA/Cursor/User/settings.json"
else
    echo "❌ Неизвестная ОС: $OSTYPE"
    exit 1
fi

echo "📁 Путь к настройкам: $SETTINGS_FILE"

# Создаем директорию, если её нет
mkdir -p "$(dirname "$SETTINGS_FILE")"

# Проверяем, существует ли файл
if [ -f "$SETTINGS_FILE" ]; then
    echo "✅ Файл настроек найден, обновляем..."
    
    # Используем Python для безопасного обновления JSON
    python3 << PYTHON_SCRIPT
import json
import os
import sys

settings_file = "$SETTINGS_FILE"
try:
    with open(settings_file, 'r', encoding='utf-8') as f:
        settings = json.load(f)
except Exception as e:
    print(f"⚠️  Ошибка чтения файла: {e}")
    settings = {}

# Отключаем все звуковые уведомления
settings["workbench.sounds.enabled"] = False
settings["audioCues.enabled"] = "off"
settings["cursor.sound.enabled"] = False
settings["cursor.audioNotifications"] = False

try:
    with open(settings_file, 'w', encoding='utf-8') as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
    print("✅ Настройки успешно обновлены!")
    print("🔄 Перезапустите Cursor для применения изменений")
except Exception as e:
    print(f"❌ Ошибка записи файла: {e}")
    sys.exit(1)
PYTHON_SCRIPT

else
    echo "📝 Файл настроек не найден, создаем новый..."
    cat > "$SETTINGS_FILE" << JSON
{
  "workbench.sounds.enabled": false,
  "audioCues.enabled": "off",
  "cursor.sound.enabled": false,
  "cursor.audioNotifications": false
}
JSON
    echo "✅ Файл настроек создан!"
    echo "🔄 Перезапустите Cursor для применения изменений"
fi

echo ""
echo "✨ Готово! Звуковые уведомления отключены."
echo "💡 Если звук не прекратился, перезапустите Cursor."



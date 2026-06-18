#!/bin/bash

# Скрипт для настройки ADB на сервере для работы с удаленным устройством
# Использование: /opt/grani/scripts/setup_adb_remote_server.sh [--port PORT] [--auto-connect]

set -euo pipefail

ADB_PORT="${1:-5555}"
AUTO_CONNECT="${2:-false}"

ANDROID_SDK_ROOT="/opt/android-sdk"
export PATH="${PATH}:${ANDROID_SDK_ROOT}/platform-tools"

echo "=========================================="
echo "  Настройка ADB на сервере"
echo "=========================================="
echo ""
echo "Ожидаемый порт: $ADB_PORT"
echo ""

# Проверка ADB
if ! command -v adb &> /dev/null; then
    echo "❌ Ошибка: ADB не найден"
    echo "   Проверьте установку Android SDK Platform Tools"
    exit 1
fi

echo "✅ ADB найден: $(which adb)"
echo ""

# Проверка подключения через туннель
echo "[1/3] Проверка подключения через туннель..."
if adb connect "localhost:$ADB_PORT" 2>&1 | grep -q "connected\|already connected"; then
    echo "   ✅ Устройство подключено через туннель"
    CONNECTED=true
else
    echo "   ⚠️  Устройство не подключено"
    echo ""
    echo "💡 Убедитесь, что:"
    echo "   1. SSH туннель создан на клиентской машине"
    echo "   2. Устройство подключено к ADB на клиентской машине"
    echo "   3. Туннель активен (ssh -R $ADB_PORT:localhost:$ADB_PORT)"
    CONNECTED=false
fi
echo ""

# Проверка устройств
echo "[2/3] Проверка доступных устройств..."
DEVICES=$(adb devices | grep -v "List" | grep -v "^$" || echo "")

if [ -z "$DEVICES" ]; then
    echo "   ❌ Устройства не найдены"
else
    echo "   Найденные устройства:"
    echo "$DEVICES" | sed 's/^/      /'
fi
echo ""

# Автоматическое подключение
if [ "$AUTO_CONNECT" = "true" ] && [ "$CONNECTED" = false ]; then
    echo "[3/3] Попытка автоматического подключения..."
    for i in {1..5}; do
        echo "   Попытка $i/5..."
        if adb connect "localhost:$ADB_PORT" 2>&1 | grep -q "connected\|already connected"; then
            echo "   ✅ Устройство подключено!"
            CONNECTED=true
            break
        fi
        sleep 2
    done
else
    echo "[3/3] Автоматическое подключение пропущено"
fi
echo ""

# Итоги
echo "=========================================="
if [ "$CONNECTED" = true ]; then
    echo "  ✅ Устройство готово к использованию!"
    echo "=========================================="
    echo ""
    echo "📱 Доступные команды:"
    echo "   adb devices                    # Список устройств"
    echo "   adb shell                     # Подключение к shell"
    echo "   adb logcat                    # Просмотр логов"
    echo "   /opt/grani/scripts/start_logcat_monitor.sh  # Мониторинг логов"
    echo ""
    echo "🚀 Запуск приложения:"
    echo "   /opt/grani/scripts/run_app_with_logging.sh"
    echo ""
else
    echo "  ⚠️  Устройство не подключено"
    echo "=========================================="
    echo ""
    echo "💡 Инструкции:"
    echo "   1. На клиентской машине запустите:"
    echo "      ./setup_adb_remote_client.sh"
    echo ""
    echo "   2. Или создайте SSH туннель вручную:"
    echo "      ssh -R $ADB_PORT:localhost:$ADB_PORT user@$(hostname -I | awk '{print $1}') -N"
    echo ""
    echo "   3. Затем выполните на сервере:"
    echo "      adb connect localhost:$ADB_PORT"
    echo ""
fi

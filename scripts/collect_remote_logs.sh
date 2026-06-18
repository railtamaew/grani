#!/bin/bash

# Скрипт для автоматического сбора логов с удаленного устройства
# Использование: /opt/grani/scripts/collect_remote_logs.sh [--device DEVICE] [--duration SECONDS]

set -euo pipefail

PACKAGE_NAME="com.granivpn.mobile"
LOG_DIR="/opt/grani/logs/android/remote"
DURATION="${1:-300}"  # По умолчанию 5 минут
DEVICE="${2:-}"

mkdir -p "$LOG_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/remote_logcat_${TIMESTAMP}.log"
PID_FILE="${LOG_DIR}/logcat.pid"

echo "=========================================="
echo "  Сбор логов с удаленного устройства"
echo "=========================================="
echo ""

# Проверка ADB
if ! command -v adb &> /dev/null; then
    echo "❌ Ошибка: ADB не найден"
    exit 1
fi

# Остановка предыдущего процесса
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if ps -p $OLD_PID > /dev/null 2>&1; then
        kill $OLD_PID 2>/dev/null || true
        echo "Остановлен предыдущий процесс logcat (PID: $OLD_PID)"
    fi
    rm -f "$PID_FILE"
fi

# Поиск устройства
echo "[1/4] Поиск устройства..."
if [ -z "$DEVICE" ]; then
    DEVICES=$(adb devices | grep -v "List" | grep "device" | awk '{print $1}' || echo "")
    
    if [ -z "$DEVICES" ]; then
        echo "   ❌ Устройства не найдены"
        echo ""
        echo "💡 Убедитесь, что:"
        echo "   1. Устройство подключено через SSH туннель"
        echo "   2. Выполнено: adb connect localhost:5555"
        exit 1
    fi
    
    DEVICE=$(echo "$DEVICES" | head -1)
fi

echo "   ✅ Устройство: $DEVICE"
echo ""

# Проверка подключения
echo "[2/4] Проверка подключения..."
if ! adb -s "$DEVICE" shell "echo 'test'" > /dev/null 2>&1; then
    echo "   ❌ Не удалось подключиться к устройству"
    exit 1
fi
echo "   ✅ Подключение работает"
echo ""

# Очистка старых логов
echo "[3/4] Очистка старых логов..."
adb -s "$DEVICE" logcat -c > /dev/null 2>&1
echo "   ✅ Логи очищены"
echo ""

# Запуск сбора логов
echo "[4/4] Запуск сбора логов..."
echo "   Длительность: $DURATION секунд"
echo "   Логи сохраняются в: $LOG_FILE"
echo ""

# Запускаем logcat с фильтрацией
(
    adb -s "$DEVICE" logcat \
      | grep --line-buffered -E "($PACKAGE_NAME|GraniVpnService|VpnPlugin|VpnService|SingBoxWrapper|SingBoxPlatform|libbox|flutter|AndroidRuntime|VpnException|VPN|vpn|ERROR|Exception)" \
      | tee "$LOG_FILE" &
    
    LOGCAT_PID=$!
    echo $LOGCAT_PID > "$PID_FILE"
    
    # Ждем указанное время
    sleep "$DURATION"
    
    # Останавливаем logcat
    kill $LOGCAT_PID 2>/dev/null || true
    rm -f "$PID_FILE"
    
    echo ""
    echo "=========================================="
    echo "  ✅ Сбор логов завершен"
    echo "=========================================="
    echo ""
    echo "📝 Логи сохранены в: $LOG_FILE"
    echo "📊 Размер файла: $(du -h "$LOG_FILE" | awk '{print $1}')"
    echo "📈 Строк логов: $(wc -l < "$LOG_FILE")"
    echo ""
) &

COLLECT_PID=$!

echo "   ✅ Сбор логов запущен (PID: $COLLECT_PID)"
echo "   📝 Логи сохраняются в: $LOG_FILE"
echo ""
echo "💡 Для просмотра логов в реальном времени:"
echo "   tail -f $LOG_FILE"
echo ""
echo "🛑 Для остановки:"
echo "   kill $COLLECT_PID"
echo "   или"
echo "   kill \$(cat $PID_FILE)"
echo ""

# Ждем завершения
wait $COLLECT_PID

#!/bin/bash

# Скрипт для проверки логов минимального VPN приложения
# Использование: ./CHECK_LOGS.sh

echo "🔍 Проверка логов минимального VPN приложения"
echo ""

# Проверка API
echo "1️⃣ Проверка API endpoint..."
API_RESPONSE=$(curl -s -X POST http://159.223.199.122:8000/api/vpn/logs/test \
  -H "Content-Type: application/json" \
  -d '{"app":"test","logs":[{"timestamp":"2026-01-20T12:00:00.000Z","level":"INFO","tag":"Test","message":"Test"}]}')

if echo "$API_RESPONSE" | grep -q "ok.*true"; then
    echo "   ✅ API работает"
else
    echo "   ❌ API не отвечает"
    echo "   Ответ: $API_RESPONSE"
fi
echo ""

# Проверка директорий
echo "2️⃣ Проверка директорий логов..."
LOG_DIRS=("/tmp/vpn_minimal_logs" "/opt/grani/logs/test_apps")

for dir in "${LOG_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        echo "   ✅ $dir существует"
        LOG_COUNT=$(find "$dir" -name "*.log" -type f 2>/dev/null | wc -l)
        echo "      Файлов: $LOG_COUNT"
    else
        echo "   ⚠️  $dir не существует"
    fi
done
echo ""

# Поиск логов
echo "3️⃣ Поиск логов..."
TODAY=$(date +%Y%m%d)
LOG_FILES=(
    "/tmp/vpn_minimal_logs/vpn-minimal_${TODAY}.log"
    "/opt/grani/logs/test_apps/vpn-minimal_${TODAY}.log"
)

FOUND=false
for log_file in "${LOG_FILES[@]}"; do
    if [ -f "$log_file" ]; then
        FOUND=true
        LOG_SIZE=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo "0")
        LOG_LINES=$(wc -l < "$log_file" 2>/dev/null || echo "0")
        
        echo "   ✅ Файл найден: $log_file"
        echo "   📊 Размер: ${LOG_SIZE} байт"
        echo "   📊 Строк: ${LOG_LINES}"
        echo ""
        echo "   📝 Последние 30 строк:"
        echo "   ----------------------------------------"
        tail -30 "$log_file" | sed 's/^/   /'
        echo "   ----------------------------------------"
        break
    fi
done

if [ "$FOUND" = false ]; then
    echo "   ⚠️  Логи еще не созданы"
    echo "   💡 Логи создаются автоматически при отправке с устройства"
    echo "   💡 Отправка происходит каждые 30 секунд или при накоплении 10+ логов"
fi
echo ""

# Мониторинг в реальном времени
echo "4️⃣ Запуск мониторинга в реальном времени..."
echo "   (Нажмите Ctrl+C для остановки)"
echo "   ----------------------------------------"

# Находим файл для мониторинга
MONITOR_FILE=""
for log_file in "${LOG_FILES[@]}"; do
    if [ -f "$log_file" ]; then
        MONITOR_FILE="$log_file"
        break
    fi
done

if [ -n "$MONITOR_FILE" ]; then
    tail -f "$MONITOR_FILE"
else
    echo "   ⏳ Ожидание появления логов..."
    # Ждем появления файла
    while [ ! -f "${LOG_FILES[0]}" ] && [ ! -f "${LOG_FILES[1]}" ]; do
        sleep 2
        for log_file in "${LOG_FILES[@]}"; do
            if [ -f "$log_file" ]; then
                echo "   ✅ Файл появился: $log_file"
                tail -f "$log_file"
                exit 0
            fi
        done
    done
fi

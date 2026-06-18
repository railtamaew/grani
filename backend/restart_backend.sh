#!/bin/bash
# Скрипт для перезапуска бэкенда

echo "🔄 Перезапуск бэкенда GraniVPN..."

# Находим процесс uvicorn
PID=$(ps aux | grep -E "uvicorn.*main:app" | grep -v grep | awk '{print $2}')

if [ -n "$PID" ]; then
    echo "Остановка текущего процесса (PID: $PID)..."
    kill $PID
    sleep 2
    
    # Проверяем, что процесс остановлен
    if ps -p $PID > /dev/null 2>&1; then
        echo "Принудительная остановка..."
        kill -9 $PID
        sleep 1
    fi
else
    echo "Процесс не найден, запускаем новый..."
fi

# Переходим в директорию бэкенда
cd /opt/grani/backend

# Запускаем бэкенд
echo "Запуск бэкенда..."
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/grani-backend.log 2>&1 &
NEW_PID=$!

sleep 2

# Проверяем, что процесс запустился
if ps -p $NEW_PID > /dev/null 2>&1; then
    echo "✅ Бэкенд успешно запущен (PID: $NEW_PID)"
    echo "Логи: /tmp/grani-backend.log"
    echo "Проверка статуса: tail -f /tmp/grani-backend.log"
else
    echo "❌ Ошибка запуска бэкенда. Проверьте логи: /tmp/grani-backend.log"
    exit 1
fi







#!/bin/bash
# Скрипт для проверки статуса сборки APK

echo "=== Проверка статуса сборки APK ==="
echo ""

# Проверка процесса сборки
if ps aux | grep -q "[f]lutter build"; then
    echo "✅ Процесс сборки активен"
    ps aux | grep "[f]lutter build" | head -1
else
    echo "ℹ️ Процесс сборки не найден"
fi

echo ""
echo "=== Проверка APK ==="

# Проверка release APK (приоритет)
if [ -f /opt/grani/mobile-app/build/app/outputs/flutter-apk/app-release.apk ]; then
    echo "✅ Release APK найден!"
    ls -lh /opt/grani/mobile-app/build/app/outputs/flutter-apk/app-release.apk
    echo ""
    echo "Дата модификации:"
    stat /opt/grani/mobile-app/build/app/outputs/flutter-apk/app-release.apk | grep Modify
    echo ""
    
    # Копируем в корень
    cp /opt/grani/mobile-app/build/app/outputs/flutter-apk/app-release.apk /opt/grani/granivpn-release.apk
    chmod 644 /opt/grani/granivpn-release.apk
    echo "✅ Скопирован в /opt/grani/granivpn-release.apk"
    echo ""
elif [ -f /opt/grani/mobile-app/build/app/outputs/flutter-apk/app-debug.apk ]; then
    echo "✅ Debug APK найден!"
    ls -lh /opt/grani/mobile-app/build/app/outputs/flutter-apk/app-debug.apk
    echo ""
    echo "Дата модификации:"
    stat /opt/grani/mobile-app/build/app/outputs/flutter-apk/app-debug.apk | grep Modify
    echo ""
    
    # Копируем в корень
    cp /opt/grani/mobile-app/build/app/outputs/flutter-apk/app-debug.apk /opt/grani/granivpn-debug.apk
    chmod 644 /opt/grani/granivpn-debug.apk
    echo "✅ Скопирован в /opt/grani/granivpn-debug.apk"
    echo ""
else
    echo "❌ APK еще не собран"
    echo ""
    echo "Последние строки лога:"
    tail -20 /tmp/flutter_build_*.log 2>/dev/null | tail -10 || echo "Лог не найден"
    exit 1
fi

# Проверка и запуск веб-сервера
echo "=== Проверка веб-сервера ==="
if ! netstat -tlnp 2>/dev/null | grep -q ":8001 " && ! ss -tlnp 2>/dev/null | grep -q ":8001 "; then
    echo "⚠️  Веб-сервер на порту 8001 не запущен. Запускаю..."
    cd /opt/grani
    nohup python3 -m http.server 8001 > /dev/null 2>&1 &
    sleep 2
    if netstat -tlnp 2>/dev/null | grep -q ":8001 " || ss -tlnp 2>/dev/null | grep -q ":8001 "; then
        echo "✅ Веб-сервер запущен"
    else
        echo "❌ Не удалось запустить веб-сервер"
    fi
else
    echo "✅ Веб-сервер уже запущен"
fi

echo ""
echo "Ссылки на скачивание:"
if [ -f /opt/grani/granivpn-release.apk ]; then
    echo "  Release: http://159.223.199.122:8001/granivpn-release.apk"
fi
if [ -f /opt/grani/granivpn-debug.apk ]; then
    echo "  Debug:   http://159.223.199.122:8001/granivpn-debug.apk"
fi

echo ""
echo "Текущее время:"
date

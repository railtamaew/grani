#!/usr/bin/env bash
# Скрипт запуска приложения на эмуляторе с полным логированием
# Использование: /opt/grani/scripts/run_app_with_logging.sh

set -euo pipefail

PACKAGE_NAME="com.granivpn.mobile"
LOG_DIR="/opt/grani/logs/android"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/app_run_${TIMESTAMP}.log"
APK_PATH="/opt/grani/mobile-app/build/app/outputs/flutter-apk/app-debug.apk"

echo "=========================================="
echo "  Запуск приложения с полным логированием"
echo "=========================================="
echo ""

# Проверка эмулятора (таймаут 5 секунд)
echo "[1/6] Проверка эмулятора..."
if ! timeout 5 adb wait-for-device 2>/dev/null; then
    echo "❌ Эмулятор не найден"
    echo "Запустите сначала: /opt/grani/scripts/start_combined_testing.sh manual"
    exit 1
fi

DEVICE=$(adb devices | grep "device$" | awk '{print $1}' | head -1)
echo "   ✅ Устройство найдено: $DEVICE"

# Проверка APK
echo ""
echo "[2/6] Проверка APK..."
if [ ! -f "$APK_PATH" ]; then
    echo "   APK не найден, собираем..."
    cd /opt/grani/mobile-app
    flutter build apk --debug
    if [ ! -f "$APK_PATH" ]; then
        echo "❌ Не удалось собрать APK"
        exit 1
    fi
fi
echo "   ✅ APK найден: $APK_PATH"

# Остановка предыдущего logcat
echo ""
echo "[3/6] Остановка предыдущего logcat..."
pkill -f "adb.*logcat.*${PACKAGE_NAME}" 2>/dev/null || true
sleep 1

# Очистка логов
echo ""
echo "[4/6] Очистка старых логов..."
adb -s "$DEVICE" logcat -c

# Установка APK
echo ""
echo "[5/6] Установка APK..."
adb -s "$DEVICE" install -r "$APK_PATH" 2>&1 | tee -a "$LOG_FILE"
echo "   ✅ APK установлен"

# Запуск мониторинга логов
echo ""
echo "[6/6] Запуск мониторинга логов..."
adb -s "$DEVICE" logcat \
  | grep --line-buffered -E "($PACKAGE_NAME|GraniVpnService|VpnPlugin|VpnService|SingBoxWrapper|SingBoxPlatform|libbox|flutter|AndroidRuntime|VpnException|VpnPermissionException|VPN|vpn)" \
  | tee "$LOG_FILE" &

LOGCAT_PID=$!
echo "   ✅ Logcat запущен (PID: $LOGCAT_PID)"
echo "   📝 Логи сохраняются в: $LOG_FILE"

# Запуск приложения
echo ""
echo "Запуск приложения..."
adb -s "$DEVICE" shell am start -n "${PACKAGE_NAME}/.MainActivity" 2>&1 | tee -a "$LOG_FILE"
sleep 1

echo ""
echo "=========================================="
echo "  Приложение запущено!"
echo "=========================================="
echo ""
echo "📱 Приложение запущено на эмуляторе"
echo ""
echo "📊 Логи в реальном времени:"
echo "   tail -f $LOG_FILE"
echo ""
echo "💡 Инструкции:"
echo "   1. Откройте браузер: http://$(hostname -I | awk '{print $1}'):6080/vnc.html"
echo "   2. В браузере вы увидите экран эмулятора"
echo "   3. В приложении выберите сервер и протокол"
echo "   4. Нажмите 'Подключиться'"
echo "   5. Когда появится диалог разрешения VPN - нажмите 'Разрешить'"
echo "   6. Наблюдайте логи в реальном времени"
echo ""
echo "🛑 Для остановки:"
echo "   kill $LOGCAT_PID"
echo "   или"
echo "   /opt/grani/scripts/stop_logcat_monitor.sh"
echo ""

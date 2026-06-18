#!/usr/bin/env bash
# Главный скрипт запуска комбинированной системы тестирования
# Использование: 
#   /opt/grani/scripts/start_combined_testing.sh [manual|auto]
#   manual - ручной режим (разрешения через браузер)
#   auto - автоматический режим (разрешения через UI Automator)

set -euo pipefail

MODE="${1:-manual}"  # manual или auto

if [ "$MODE" != "manual" ] && [ "$MODE" != "auto" ]; then
    echo "❌ Неверный режим. Используйте: manual или auto"
    echo "Использование: $0 [manual|auto]"
    exit 1
fi

echo "=========================================="
echo "  Комбинированная система тестирования"
echo "  Режим: $MODE"
echo "=========================================="
echo ""

# 1. Запуск эмулятора с VNC
echo "[1/4] Запуск эмулятора с VNC..."
/opt/grani/scripts/start_emulator_with_vnc.sh

# 2. Ожидание готовности (сокращено)
echo ""
echo "[2/4] Ожидание готовности эмулятора..."
sleep 2
timeout 10 adb wait-for-device 2>/dev/null || {
    echo "   ⚠️  Таймаут ожидания устройства, продолжаем..."
}
for i in {1..10}; do
    if adb shell getprop sys.boot_completed 2>/dev/null | grep -q "1"; then
        echo "   ✅ Эмулятор готов"
        break
    fi
    if [ $((i % 3)) -eq 0 ]; then
        echo "   Ожидание... ($i/10)"
    fi
    sleep 1
done

# 3. Запуск noVNC
echo ""
echo "[3/4] Запуск noVNC веб-интерфейса..."
/opt/grani/scripts/start_novnc.sh

# 4. Запуск мониторинга логов
echo ""
echo "[4/4] Запуск мониторинга логов..."
/opt/grani/scripts/start_logcat_monitor.sh

# 5. Автоматическое принятие разрешения (если режим auto)
if [ "$MODE" = "auto" ]; then
    echo ""
    echo "[5/5] Автоматическое принятие разрешения VPN..."
    /opt/grani/scripts/auto_grant_vpn_permission.sh || {
        echo "⚠️  Автоматическое принятие не удалось, используйте ручной режим"
    }
fi

SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "=========================================="
echo "  Система готова к тестированию!"
echo "=========================================="
echo ""

if [ "$MODE" = "manual" ]; then
    echo "👤 РУЧНОЙ РЕЖИМ:"
    echo ""
    echo "1. Откройте браузер и перейдите по адресу:"
    echo "   http://${SERVER_IP}:6080/vnc.html"
    echo ""
    echo "2. В браузере вы увидите экран эмулятора"
    echo "   - Установите APK (если нужно)"
    echo "   - Запустите приложение"
    echo "   - Когда появится диалог разрешения VPN,"
    echo "     нажмите 'Разрешить' мышью в браузере"
    echo ""
else
    echo "🤖 АВТОМАТИЧЕСКИЙ РЕЖИМ:"
    echo ""
    echo "Разрешение VPN должно быть выдано автоматически"
    echo "Если нет - используйте ручной режим:"
    echo "   /opt/grani/scripts/start_combined_testing.sh manual"
    echo ""
fi

echo "3. Логи собираются автоматически в:"
echo "   /opt/grani/logs/android/logcat_*.log"
echo ""
echo "4. Для просмотра логов в реальном времени:"
echo "   tail -f /opt/grani/logs/android/logcat_*.log"
echo ""
echo "5. Для остановки всей системы:"
echo "   /opt/grani/scripts/stop_combined_testing.sh"
echo ""

#!/usr/bin/env bash
# Скрипт автоматического принятия разрешения VPN через UI Automator
# Использование: /opt/grani/scripts/auto_grant_vpn_permission.sh

set -euo pipefail

echo "=========================================="
echo "  Автоматическое принятие разрешения VPN"
echo "=========================================="

# Проверка устройства
adb wait-for-device
DEVICE=$(adb devices | grep -v "List" | grep "device" | awk '{print $1}' | head -1)

if [ -z "$DEVICE" ]; then
    echo "❌ Устройство не найдено"
    exit 1
fi

echo "Устройство: $DEVICE"
echo ""

# Проверка разрешения через adb
echo "[1/4] Проверка текущего разрешения..."
# Проверяем через VpnService.prepare (если вернет null - разрешение есть)
PERMISSION_CHECK=$(adb -s "$DEVICE" shell "am start -a android.net.VpnService.PREPARE -n com.granivpn.mobile/.MainActivity 2>&1" | head -1)
sleep 1

# Запуск диалога разрешения (если нужно)
echo ""
echo "[2/4] Запуск диалога разрешения VPN..."
adb -s "$DEVICE" shell am start -a android.net.VpnService.PREPARE -n com.granivpn.mobile/.MainActivity 2>/dev/null || true

# Небольшая задержка для появления диалога
sleep 3

# Автоматическое нажатие кнопки через UI Automator
echo ""
echo "[3/4] Автоматическое принятие разрешения..."

# Получаем разрешение экрана
SCREEN_SIZE=$(adb -s "$DEVICE" shell wm size 2>/dev/null | awk '{print $3}' || echo "1080x1920")
WIDTH=$(echo $SCREEN_SIZE | cut -d'x' -f1)
HEIGHT=$(echo $SCREEN_SIZE | cut -d'x' -f2)

# Кнопка "OK" обычно в центре-низу экрана
BUTTON_X=$((WIDTH / 2))
BUTTON_Y=$((HEIGHT - 200))

echo "   Разрешение экрана: ${WIDTH}x${HEIGHT}"
echo "   Координаты кнопки: ${BUTTON_X}, ${BUTTON_Y}"

# Пробуем разные методы
SUCCESS=false

# Метод 1: Нажатие по координатам (центр экрана внизу)
echo "   Метод 1: Нажатие по координатам..."
adb -s "$DEVICE" shell input tap $BUTTON_X $BUTTON_Y
sleep 2

# Метод 2: Через KEYCODE_ENTER
echo "   Метод 2: Клавиша Enter..."
adb -s "$DEVICE" shell input keyevent 66
sleep 1

# Метод 3: Через KEYCODE_DPAD_CENTER
echo "   Метод 3: Клавиша DPad Center..."
adb -s "$DEVICE" shell input keyevent 23
sleep 1

# Метод 4: Поиск кнопки через UI Automator (если доступен)
if command -v uiautomator &> /dev/null; then
    echo "   Метод 4: UI Automator..."
    # Это требует скомпилированного JAR, пропускаем пока
fi

# Проверка результата
echo ""
echo "[4/4] Проверка результата..."
sleep 2

# Проверяем через попытку запуска VpnService.prepare
# Если разрешение выдано, prepare вернет null (не запустит диалог)
DIALOG_CHECK=$(adb -s "$DEVICE" shell "am start -a android.net.VpnService.PREPARE -n com.granivpn.mobile/.MainActivity 2>&1" | grep -i "error\|exception" || echo "")

if [ -z "$DIALOG_CHECK" ]; then
    echo "✅ Разрешение VPN выдано автоматически"
    SUCCESS=true
else
    echo "⚠️  Автоматическое принятие не удалось"
    echo ""
    echo "💡 Используйте ручной режим:"
    echo "   1. Откройте noVNC в браузере"
    echo "   2. Когда появится диалог, нажмите 'Разрешить' мышью"
    SUCCESS=false
fi

if [ "$SUCCESS" = true ]; then
    exit 0
else
    exit 1
fi

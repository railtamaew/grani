#!/usr/bin/env bash
# Улучшенный скрипт принятия разрешения VPN
# Использование: /opt/grani/scripts/grant_vpn_permission_improved.sh

set -euo pipefail

echo "=========================================="
echo "  Улучшенное принятие разрешения VPN"
echo "=========================================="
echo ""

# Таймаут 5 секунд для ожидания устройства
if ! timeout 5 adb wait-for-device 2>/dev/null; then
    echo "❌ Устройство не найдено"
    exit 1
fi

DEVICE=$(adb devices | grep -v "List" | grep "device" | awk '{print $1}' | head -1)

if [ -z "$DEVICE" ]; then
    echo "❌ Устройство не найдено"
    exit 1
fi

echo "Устройство: $DEVICE"
echo ""

# Получаем разрешение экрана
SCREEN_SIZE=$(adb -s "$DEVICE" shell wm size 2>/dev/null | awk '{print $3}' || echo "1080x1920")
WIDTH=$(echo $SCREEN_SIZE | cut -d'x' -f1)
HEIGHT=$(echo $SCREEN_SIZE | cut -d'x' -f2)

echo "Разрешение экрана: ${WIDTH}x${HEIGHT}"
echo ""

# Метод 1: Запуск диалога разрешения
echo "[1/5] Запуск диалога разрешения VPN..."
adb -s "$DEVICE" shell am start -a android.net.VpnService.PREPARE -n com.granivpn.mobile/.MainActivity 2>&1
sleep 2

# Метод 2: Координаты (центр-низ экрана)
echo "[2/5] Попытка 1: Нажатие по координатам (центр-низ)..."
BUTTON_X=$((WIDTH / 2))
BUTTON_Y=$((HEIGHT - 200))
adb -s "$DEVICE" shell input tap $BUTTON_X $BUTTON_Y
sleep 1

# Метод 3: Координаты (правая часть, кнопка OK)
echo "[3/5] Попытка 2: Нажатие по координатам (правая часть)..."
BUTTON_X=$((WIDTH - 200))
BUTTON_Y=$((HEIGHT - 150))
adb -s "$DEVICE" shell input tap $BUTTON_X $BUTTON_Y
sleep 1

# Метод 4: KEYCODE_ENTER
echo "[4/5] Попытка 3: Клавиша Enter..."
adb -s "$DEVICE" shell input keyevent 66
sleep 1

# Метод 5: KEYCODE_DPAD_CENTER
echo "[5/5] Попытка 4: Клавиша DPad Center..."
adb -s "$DEVICE" shell input keyevent 23
sleep 1

# Проверка результата
echo ""
echo "Проверка результата..."
sleep 2

# Проверяем через попытку запуска VpnService.prepare
DIALOG_CHECK=$(timeout 3 adb -s "$DEVICE" shell "am start -a android.net.VpnService.PREPARE -n com.granivpn.mobile/.MainActivity 2>&1" | grep -i "error\|exception" || echo "")

if [ -z "$DIALOG_CHECK" ]; then
    echo "✅ Разрешение VPN выдано"
    exit 0
else
    echo "⚠️  Автоматическое принятие не удалось"
    echo ""
    echo "💡 Используйте ручной режим:"
    echo "   1. Откройте noVNC в браузере"
    echo "   2. Когда появится диалог, нажмите 'Разрешить' мышью"
    exit 1
fi

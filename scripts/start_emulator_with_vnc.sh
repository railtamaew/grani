#!/usr/bin/env bash
# Скрипт запуска эмулятора Android с VNC поддержкой
# Использование: /opt/grani/scripts/start_emulator_with_vnc.sh

set -euo pipefail

ANDROID_SDK_ROOT="/opt/android-sdk"
AVD_NAME="${AVD_NAME:-grani_light}"  # Используем grani_light по умолчанию (меньше места)
VNC_DISPLAY=":1"
VNC_PORT=5901

echo "=========================================="
echo "  Запуск эмулятора с VNC поддержкой"
echo "=========================================="

# Экспорт переменных окружения
export ANDROID_SDK_ROOT
export PATH="${PATH}:${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${ANDROID_SDK_ROOT}/emulator"
# Исправление LD_LIBRARY_PATH для работы эмулятора (добавлены системные библиотеки)
export LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu:${ANDROID_SDK_ROOT}/emulator/lib64:${ANDROID_SDK_ROOT}/emulator/lib64/qt/lib:${LD_LIBRARY_PATH:-}"

# Проверка существующего эмулятора
if pgrep -f "emulator.*${AVD_NAME}" > /dev/null; then
    echo "✅ Эмулятор уже запущен"
    timeout 5 adb wait-for-device 2>/dev/null || true
    exit 0
fi

# Проверка AVD
if ! avdmanager list avd 2>/dev/null | grep -q "${AVD_NAME}"; then
    echo "❌ AVD '${AVD_NAME}' не найден"
    echo "Создайте AVD: /opt/grani/setup_emulator.sh"
    exit 1
fi

echo ""
echo "[1/3] Запуск эмулятора с VNC..."

# Запуск эмулятора с VNC (не headless!)
# Используем оптимальные параметры для стабильности
# Параметры соответствуют настройкам AVD в config.ini
nohup emulator -avd "${AVD_NAME}" \
  -gpu swiftshader_indirect \
  -no-snapshot -no-boot-anim \
  -no-audio \
  -netdelay none -netspeed full \
  -memory 1536 -cores 1 \
  -partition-size 2048 \
  -no-accel \
  -wipe-data \
  -qemu -vnc ${VNC_DISPLAY} \
  >/opt/android-sdk/emulator.log 2>&1 &

EMULATOR_PID=$!
echo "   Эмулятор запущен (PID: $EMULATOR_PID)"

echo ""
echo "[2/3] Ожидание загрузки эмулятора..."
timeout 10 adb wait-for-device 2>/dev/null || {
    echo "   ⚠️  Таймаут ожидания устройства, продолжаем..."
}

# Ждем полной загрузки (сокращено до 15 итераций по 1 секунде = 15 секунд)
for i in {1..15}; do
    if adb shell getprop sys.boot_completed 2>/dev/null | grep -q "1"; then
        echo "   ✅ Эмулятор загружен"
        break
    fi
    if [ $((i % 5)) -eq 0 ]; then
        echo "   Ожидание... ($i/15)"
    fi
    sleep 1
done

if ! adb shell getprop sys.boot_completed 2>/dev/null | grep -q "1"; then
    echo "   ⚠️  Эмулятор загружается медленно, продолжаем..."
fi

echo ""
echo "[3/3] Проверка VNC..."
sleep 2
if nc -z localhost $VNC_PORT 2>/dev/null; then
    echo "   ✅ VNC доступен на порту ${VNC_PORT}"
else
    echo "   ⚠️  VNC может быть еще не готов, подождите несколько секунд"
fi

echo ""
echo "=========================================="
echo "  Эмулятор готов!"
echo "=========================================="
echo ""
echo "VNC доступен на: localhost:${VNC_PORT}"
echo "Для подключения через noVNC запустите:"
echo "  /opt/grani/scripts/start_novnc.sh"
echo ""

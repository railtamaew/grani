#!/usr/bin/env bash
# Скрипт пересоздания AVD с оптимальными параметрами для стабильной работы
# Использование: /opt/grani/scripts/recreate_avd_optimized.sh [AVD_NAME]
# По умолчанию: grani_optimized

set -euo pipefail

ANDROID_SDK_ROOT="/opt/android-sdk"
AVD_NAME="${1:-grani_optimized}"
API_LEVEL="30"
SYSTEM_IMAGE="system-images;android-${API_LEVEL};default;x86_64"
DEVICE_PROFILE="pixel_5"  # Используем pixel_5 вместо pixel для лучшей совместимости

# Экспорт переменных
export ANDROID_SDK_ROOT
export PATH="${PATH}:${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${ANDROID_SDK_ROOT}/emulator"
export LD_LIBRARY_PATH="${ANDROID_SDK_ROOT}/emulator/lib64:${ANDROID_SDK_ROOT}/emulator/lib64/qt/lib:${LD_LIBRARY_PATH:-}"

echo "=========================================="
echo "  Пересоздание AVD с оптимальными параметрами"
echo "  Имя: $AVD_NAME"
echo "=========================================="
echo ""

# Проверка ресурсов
echo "[1/7] Проверка ресурсов..."
DISK_FREE=$(df -h / | tail -1 | awk '{print $4}' | sed 's/G//')
MEM_FREE=$(free -g | grep Mem | awk '{print $7}')

echo "   Свободно на диске: ${DISK_FREE}G"
echo "   Свободно RAM: ${MEM_FREE}G"

if (( $(echo "$DISK_FREE < 5" | bc -l 2>/dev/null || echo 0) )); then
    echo "   ⚠️  Мало места на диске, но продолжаем..."
fi

# Проверка установленного system image
echo ""
echo "[2/7] Проверка system image..."
if ! sdkmanager --list_installed 2>/dev/null | grep -q "${SYSTEM_IMAGE}"; then
    echo "   Установка system image..."
    yes | sdkmanager "${SYSTEM_IMAGE}" 2>&1 | grep -E "(Installing|Done)" || true
else
    echo "   ✅ System image уже установлен"
fi

# Удаление старого AVD (если существует)
echo ""
echo "[3/7] Удаление старого AVD (если существует)..."
if avdmanager list avd 2>/dev/null | grep -q "${AVD_NAME}"; then
    echo "   Удаление AVD: ${AVD_NAME}"
    avdmanager delete avd -n "${AVD_NAME}" 2>&1 | grep -v "^$" || true
    sleep 1
else
    echo "   AVD не найден, пропускаем удаление"
fi

# Остановка запущенных эмуляторов с этим AVD
echo ""
echo "[4/7] Остановка запущенных эмуляторов..."
pkill -f "emulator.*${AVD_NAME}" 2>/dev/null || true
sleep 2

# Создание нового AVD
echo ""
echo "[5/7] Создание нового AVD..."
echo "no" | avdmanager create avd \
  -n "${AVD_NAME}" \
  -k "${SYSTEM_IMAGE}" \
  -d "${DEVICE_PROFILE}" \
  --force 2>&1 | grep -E "(Created|Error)" || {
    echo "   ⚠️  Предупреждения при создании AVD (нормально)"
}

# Настройка config.ini с оптимальными параметрами
echo ""
echo "[6/7] Настройка config.ini с оптимальными параметрами..."
AVD_DIR="${HOME}/.android/avd/${AVD_NAME}.avd"
CONFIG_FILE="${AVD_DIR}/config.ini"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "   ❌ Файл config.ini не найден: $CONFIG_FILE"
    exit 1
fi

# Создаем резервную копию
cp "$CONFIG_FILE" "${CONFIG_FILE}.backup"

# Сохраняем существующий SDK путь из config (если есть)
EXISTING_SDK_PATH=$(grep "^android.sdk.path" "$CONFIG_FILE" | cut -d'=' -f2 | tr -d ' ' || echo "")

# Оптимальные параметры для стабильности:
# - Минимальная RAM (1536MB) для экономии ресурсов
# - 1 CPU core для стабильности
# - Отключение аудио, камер, сенсоров
# - Минимальный размер SD карты
# - Отключение Play Store
cat > "$CONFIG_FILE" <<EOF
# AVD конфигурация для стабильной работы на сервере
# Создано: $(date)

# Базовые параметры
avd.ini.encoding = UTF-8
avd.name = ${AVD_NAME}
PlayStore.enabled = no

# Система
abi.type = x86_64
target = android-${API_LEVEL}
image.sysdir.1 = system-images/android-${API_LEVEL}/default/x86_64/
hw.cpu.arch = x86_64
hw.cpu.ncore = 1
hw.ramSize = 1536

# Дисплей
hw.lcd.density = 420
hw.lcd.height = 1920
hw.lcd.width = 1080
hw.screen = multi-touch

# Отключение ненужных функций для стабильности
hw.audioInput = no
hw.audioOutput = no
hw.camera.back = none
hw.camera.front = none
hw.accelerometer = no
hw.accelerometer_uncalibrated = no
hw.gyroscope = no
hw.gps = no
hw.battery = yes
hw.sensors.proximity = no
hw.sensors.light = no
hw.sensors.pressure = no
hw.sensors.humidity = no
hw.sensors.orientation = no
hw.sensors.temperature = no

# GPU (используем swiftshader для стабильности без KVM)
hw.gpu.enabled = yes
hw.gpu.mode = swiftshader_indirect

# Сеть
hw.sdCard = no

# Загрузка
fastboot.forceChosenSnapshotBoot = no
fastboot.forceColdBoot = no
fastboot.forceFastBoot = yes

# Снимки (отключаем для стабильности)
snapshot.present = no
firstboot.bootFromDownloadableSnapshot = no
firstboot.bootFromLocalSnapshot = no
firstboot.saveToLocalSnapshot = no

# Разделы диска (минимальные размеры)
disk.cachePartition = yes
disk.cachePartition.size = 66MB
disk.dataPartition.size = 2048MB
disk.systemPartition.size = 0
disk.vendorPartition.size = 0

# Дополнительные параметры для стабильности
hw.dPad = no
hw.mainKeys = yes
hw.keyboard = yes
hw.keyboard.lid = no
hw.keyboard.charmap = qwerty2

# SDK путь (важно для корректной работы)
android.sdk.path = ${ANDROID_SDK_ROOT}
EOF

echo "   ✅ Config.ini настроен"

# Проверка конфигурации
echo ""
echo "[7/7] Проверка конфигурации..."
if [ -f "$CONFIG_FILE" ]; then
    echo "   ✅ AVD создан: ${AVD_NAME}"
    echo "   📁 Путь: ${AVD_DIR}"
    echo "   📋 Config: ${CONFIG_FILE}"
    
    # Показываем ключевые параметры
    echo ""
    echo "   Ключевые параметры:"
    grep -E "^(hw\.(ramSize|cpu\.ncore|audio|gpu\.mode)|disk\.dataPartition\.size)" "$CONFIG_FILE" | sed 's/^/      /'
else
    echo "   ❌ Ошибка: config.ini не найден"
    exit 1
fi

echo ""
echo "=========================================="
echo "  AVD успешно пересоздан!"
echo "=========================================="
echo ""
echo "📝 Имя AVD: ${AVD_NAME}"
echo ""
echo "🚀 Для запуска используйте:"
echo "   export AVD_NAME=${AVD_NAME}"
echo "   /opt/grani/scripts/start_combined_testing.sh manual"
echo ""
echo "💡 Или напрямую:"
echo "   /opt/grani/scripts/start_emulator_with_vnc.sh"
echo ""
echo "📊 Параметры AVD:"
echo "   - RAM: 1536MB"
echo "   - CPU: 1 core"
echo "   - Disk: 2048MB"
echo "   - Audio: отключен"
echo "   - Camera: отключена"
echo "   - GPU: swiftshader_indirect"
echo ""

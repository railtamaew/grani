#!/usr/bin/env bash
# Детальная диагностика проблем с эмулятором Android
# Использование: /opt/grani/scripts/diagnose_emulator.sh

set -e

ANDROID_SDK_ROOT="/opt/android-sdk"
export ANDROID_SDK_ROOT
export PATH="${PATH}:${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${ANDROID_SDK_ROOT}/emulator"
export LD_LIBRARY_PATH="${ANDROID_SDK_ROOT}/emulator/lib64:${ANDROID_SDK_ROOT}/emulator/lib64/qt/lib:${LD_LIBRARY_PATH:-}"

echo "=========================================="
echo "  ДИАГНОСТИКА ЭМУЛЯТОРА ANDROID"
echo "=========================================="
echo ""

# 1. Проверка ресурсов
echo "[1/6] Проверка ресурсов системы..."
echo "---"
echo "Диск:"
df -h / | tail -1
echo ""
echo "RAM:"
free -h | grep Mem
echo ""
echo "CPU:"
nproc
echo "---"
echo ""

# 2. Проверка библиотек
echo "[2/6] Проверка библиотек эмулятора..."
QEMU_BIN="/opt/android-sdk/emulator/qemu/linux-x86_64/qemu-system-x86_64"
if [ -f "$QEMU_BIN" ]; then
    echo "✅ qemu-system-x86_64 найден"
    MISSING_LIBS=$(ldd "$QEMU_BIN" 2>/dev/null | grep "not found" | wc -l)
    if [ "$MISSING_LIBS" -eq 0 ]; then
        echo "✅ Все библиотеки найдены"
    else
        echo "❌ Найдено отсутствующих библиотек: $MISSING_LIBS"
        echo "Отсутствующие библиотеки:"
        ldd "$QEMU_BIN" 2>/dev/null | grep "not found" | head -10
    fi
else
    echo "❌ qemu-system-x86_64 не найден"
fi
echo ""

# 3. Проверка виртуализации
echo "[3/6] Проверка виртуализации..."
if lsmod | grep -q kvm; then
    echo "✅ KVM модуль загружен"
    lsmod | grep kvm
else
    echo "⚠️  KVM модуль не загружен"
fi

CPU_VIRT=$(grep -E "vmx|svm" /proc/cpuinfo | head -1)
if [ -n "$CPU_VIRT" ]; then
    echo "✅ CPU поддерживает виртуализацию"
else
    echo "⚠️  CPU может не поддерживать виртуализацию"
fi
echo ""

# 4. Проверка AVD
echo "[4/6] Проверка AVD..."
if avdmanager list avd 2>/dev/null | grep -q "grani_light"; then
    echo "✅ AVD grani_light найден"
    echo "Детали AVD:"
    avdmanager list avd 2>/dev/null | grep -A 5 "grani_light"
    
    if [ -f "/root/.android/avd/grani_light.avd/config.ini" ]; then
        echo ""
        echo "Конфигурация AVD:"
        grep -E "disk\.|hw\.ramSize|hw\.vm\.heapSize" /root/.android/avd/grani_light.avd/config.ini 2>/dev/null | head -10
    fi
    
    echo ""
    echo "Размеры файлов AVD:"
    du -sh /root/.android/avd/grani_light.avd/*.img 2>/dev/null | sort -h | head -5
else
    echo "❌ AVD grani_light не найден"
fi
echo ""

# 5. Проверка версии эмулятора
echo "[5/6] Проверка версии эмулятора..."
if command -v emulator &> /dev/null; then
    emulator -version 2>&1 | head -3
else
    echo "❌ emulator не найден в PATH"
fi
echo ""

# 6. Проверка логов
echo "[6/6] Последние ошибки в логах..."
if [ -f "/opt/android-sdk/emulator.log" ]; then
    echo "Последние 20 строк лога:"
    tail -20 /opt/android-sdk/emulator.log | grep -E "ERROR|FATAL|Abort|core" || tail -10 /opt/android-sdk/emulator.log
else
    echo "⚠️  Лог файл не найден"
fi
echo ""

echo "=========================================="
echo "  ДИАГНОСТИКА ЗАВЕРШЕНА"
echo "=========================================="

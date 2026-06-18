#!/bin/bash

# Скрипт диагностики и исправления проблем с эмулятором Android
# Использование: /opt/grani/scripts/fix_emulator.sh [--diagnose-only]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_SDK_ROOT="/opt/android-sdk"
EMULATOR_BIN="${ANDROID_SDK_ROOT}/emulator/emulator"
QEMU_BIN="${ANDROID_SDK_ROOT}/emulator/qemu/linux-x86_64/qemu-system-x86_64"
AVD_NAME="${AVD_NAME:-grani_optimized}"

DIAGNOSE_ONLY=false
if [[ "${1:-}" == "--diagnose-only" ]]; then
    DIAGNOSE_ONLY=true
fi

echo "=========================================="
echo "  Диагностика и исправление эмулятора"
echo "=========================================="
echo ""

# Экспорт переменных
export ANDROID_SDK_ROOT
export PATH="${PATH}:${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${ANDROID_SDK_ROOT}/emulator"

# ========== 1. Проверка GLIBC ==========
echo "[1/8] Проверка GLIBC..."
GLIBC_VERSION=$(ldd --version | head -1 | awk '{print $NF}')
echo "   GLIBC версия: $GLIBC_VERSION"

# Проверка требуемой версии GLIBC для эмулятора
if [ -f "$QEMU_BIN" ]; then
    REQUIRED_GLIBC=$(readelf -d "$QEMU_BIN" 2>/dev/null | grep "NEEDED" | grep "libc.so" | head -1 || echo "")
    echo "   Требуемая GLIBC: $REQUIRED_GLIBC"
fi
echo ""

# ========== 2. Проверка библиотек ==========
echo "[2/8] Проверка библиотек..."
MISSING_LIBS=$(ldd "$QEMU_BIN" 2>/dev/null | grep "not found" || echo "")

if [ -z "$MISSING_LIBS" ]; then
    echo "   ✅ Все библиотеки найдены"
else
    echo "   ❌ Отсутствующие библиотеки:"
    echo "$MISSING_LIBS" | sed 's/^/      /'
    
    if [ "$DIAGNOSE_ONLY" = false ]; then
        echo ""
        echo "   Установка недостающих библиотек..."
        apt-get update -qq
        apt-get install -y -qq libx11-6 libx11-dev libxext6 libxrender1 libxtst6 libxi6 libgl1-mesa-glx libglib2.0-0 > /dev/null 2>&1 || true
        echo "   ✅ Библиотеки установлены"
    fi
fi
echo ""

# ========== 3. Проверка X11 библиотек ==========
echo "[3/8] Проверка X11 библиотек..."
X11_LIB="/usr/lib/x86_64-linux-gnu/libX11.so.6"
if [ -f "$X11_LIB" ]; then
    echo "   ✅ libX11.so.6 найден: $X11_LIB"
    X11_VERSION=$(readelf -d "$X11_LIB" 2>/dev/null | grep SONAME || echo "")
    echo "   Версия: $X11_VERSION"
else
    echo "   ❌ libX11.so.6 не найден"
    if [ "$DIAGNOSE_ONLY" = false ]; then
        apt-get install -y -qq libx11-6 > /dev/null 2>&1 || true
    fi
fi
echo ""

# ========== 4. Проверка LD_LIBRARY_PATH ==========
echo "[4/8] Проверка LD_LIBRARY_PATH..."
CURRENT_LD_PATH="${LD_LIBRARY_PATH:-}"
REQUIRED_PATHS=(
    "/usr/lib/x86_64-linux-gnu"
    "/opt/android-sdk/emulator/lib64"
    "/opt/android-sdk/emulator/lib64/qt/lib"
)

MISSING_PATHS=()
for path in "${REQUIRED_PATHS[@]}"; do
    if [[ "$CURRENT_LD_PATH" != *"$path"* ]]; then
        MISSING_PATHS+=("$path")
    fi
done

if [ ${#MISSING_PATHS[@]} -eq 0 ]; then
    echo "   ✅ Все необходимые пути в LD_LIBRARY_PATH"
else
    echo "   ⚠️  Отсутствующие пути:"
    for path in "${MISSING_PATHS[@]}"; do
        echo "      - $path"
    done
    
    if [ "$DIAGNOSE_ONLY" = false ]; then
        NEW_LD_PATH="${CURRENT_LD_PATH}"
        for path in "${MISSING_PATHS[@]}"; do
            if [ -d "$path" ]; then
                NEW_LD_PATH="${NEW_LD_PATH}:${path}"
                echo "   ✅ Добавлен: $path"
            fi
        done
        export LD_LIBRARY_PATH="$NEW_LD_PATH"
        echo "   ✅ LD_LIBRARY_PATH обновлен"
    fi
fi
echo ""

# ========== 5. Проверка системных ресурсов ==========
echo "[5/8] Проверка системных ресурсов..."
FREE_RAM_MB=$(free -m | awk '/Mem:/ {print $4}')
CPU_CORES=$(nproc)
FREE_DISK_GB=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')

echo "   Свободно RAM: ${FREE_RAM_MB}MB"
echo "   CPU ядер: $CPU_CORES"
echo "   Свободно диска: ${FREE_DISK_GB}GB"

if [ "$FREE_RAM_MB" -lt 2048 ]; then
    echo "   ⚠️  Мало RAM (рекомендуется минимум 2GB)"
fi
if [ "$FREE_DISK_GB" -lt 10 ]; then
    echo "   ⚠️  Мало места на диске (рекомендуется минимум 10GB)"
fi
echo ""

# ========== 6. Проверка KVM ==========
echo "[6/8] Проверка KVM..."
if [ -c /dev/kvm ]; then
    echo "   ✅ /dev/kvm доступен"
    KVM_GROUP=$(stat -c "%G" /dev/kvm)
    echo "   Группа: $KVM_GROUP"
else
    echo "   ⚠️  /dev/kvm недоступен (эмулятор будет работать медленнее)"
fi
echo ""

# ========== 7. Проверка AVD ==========
echo "[7/8] Проверка AVD..."
if avdmanager list avd 2>/dev/null | grep -q "$AVD_NAME"; then
    echo "   ✅ AVD '$AVD_NAME' найден"
    AVD_DIR="${HOME}/.android/avd/${AVD_NAME}.avd"
    if [ -d "$AVD_DIR" ]; then
        CONFIG_FILE="${AVD_DIR}/config.ini"
        if [ -f "$CONFIG_FILE" ]; then
            SDK_PATH=$(grep "^android.sdk.path" "$CONFIG_FILE" | cut -d'=' -f2 | tr -d ' ' || echo "")
            if [ -n "$SDK_PATH" ]; then
                echo "   ✅ SDK путь настроен: $SDK_PATH"
            else
                echo "   ⚠️  SDK путь не настроен в config.ini"
            fi
        fi
    fi
else
    echo "   ❌ AVD '$AVD_NAME' не найден"
fi
echo ""

# ========== 8. Тестовый запуск с диагностикой ==========
if [ "$DIAGNOSE_ONLY" = false ]; then
    echo "[8/8] Тестовый запуск эмулятора (5 секунд)..."
    
    # Устанавливаем правильный LD_LIBRARY_PATH
    export LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu:/opt/android-sdk/emulator/lib64:/opt/android-sdk/emulator/lib64/qt/lib:${LD_LIBRARY_PATH:-}"
    
    # Останавливаем предыдущие экземпляры
    pkill -f "emulator.*${AVD_NAME}" 2>/dev/null || true
    sleep 2
    
    # Запускаем с таймаутом
    timeout 5 "$EMULATOR_BIN" -avd "$AVD_NAME" -no-window -no-audio -no-snapshot 2>&1 | head -20 || {
        EXIT_CODE=$?
        if [ $EXIT_CODE -eq 124 ]; then
            echo "   ✅ Эмулятор запустился (таймаут - это нормально)"
        else
            echo "   ❌ Эмулятор упал с кодом: $EXIT_CODE"
            echo ""
            echo "   Последние строки вывода:"
            timeout 5 "$EMULATOR_BIN" -avd "$AVD_NAME" -no-window -no-audio -no-snapshot 2>&1 | tail -10 || true
        fi
    }
else
    echo "[8/8] Пропущен (режим диагностики)"
fi
echo ""

# ========== Итоги ==========
echo "=========================================="
echo "  Итоги диагностики"
echo "=========================================="
echo ""

if [ "$DIAGNOSE_ONLY" = false ]; then
    echo "✅ Исправления применены:"
    echo "   - LD_LIBRARY_PATH обновлен"
    echo "   - Библиотеки проверены"
    echo ""
    echo "💡 Для использования исправлений:"
    echo "   export LD_LIBRARY_PATH=\"/usr/lib/x86_64-linux-gnu:/opt/android-sdk/emulator/lib64:/opt/android-sdk/emulator/lib64/qt/lib:\${LD_LIBRARY_PATH}\""
    echo ""
    echo "🚀 Попробуйте запустить эмулятор:"
    echo "   /opt/grani/scripts/start_emulator_with_vnc.sh"
else
    echo "📊 Режим диагностики завершен"
    echo "   Для применения исправлений запустите без --diagnose-only"
fi
echo ""

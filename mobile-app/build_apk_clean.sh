#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "=== 🧹 ПОЛНАЯ ОЧИСТКА ПРОЕКТА ==="
echo ""

# Остановка всех daemon
echo "[1/7] Остановка Gradle daemon..."
pkill -f gradle 2>/dev/null || true
pkill -f kotlin 2>/dev/null || true
cd android && ./gradlew --stop 2>/dev/null || true
cd ..

# Очистка Flutter
echo "[2/7] Очистка Flutter..."
flutter clean

# Очистка Gradle
echo "[3/7] Очистка Gradle артефактов..."
rm -rf android/.gradle
rm -rf android/app/build
rm -rf android/build
rm -rf .gradle
rm -rf build
rm -rf .dart_tool
rm -rf .flutter-plugins
rm -rf .flutter-plugins-dependencies

# Очистка глобальных кэшей (опционально, можно закомментировать если долго)
echo "[4/7] Очистка глобальных кэшей..."
rm -rf ~/.gradle/caches/transforms-* 2>/dev/null || true
rm -rf ~/.gradle/caches/modules-2/files-2.1/org.jetbrains.kotlin/ 2>/dev/null || true
rm -rf ~/.kotlin/ 2>/dev/null || true

echo "✅ Очистка завершена"
echo ""

# Синхронизация версий
echo "=== 🔧 СИНХРОНИЗАЦИЯ ВЕРСИЙ ==="
if [ -f "scripts/sync_versions.sh" ]; then
    bash scripts/sync_versions.sh
else
    echo "⚠️  scripts/sync_versions.sh не найден"
fi
echo ""

# Получение зависимостей
echo "=== 📦 ПОЛУЧЕНИЕ ЗАВИСИМОСТЕЙ ==="
echo "[6/7] Flutter pub get..."
flutter pub get
echo ""

# Сборка
echo "=== 🔨 СБОРКА APK ==="
echo "[7/7] Сборка DEBUG APK..."
BUILD_TYPE="${1:-debug}"

if [ "$BUILD_TYPE" = "release" ]; then
    echo "Сборка RELEASE версии (arm64)..."
    flutter build apk --release --target-platform android-arm64 --no-tree-shake-icons
    APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
    OUTPUT_NAME="granivpn-release-clean.apk"
else
    echo "Сборка DEBUG версии..."
    flutter build apk --debug --no-tree-shake-icons
    APK_PATH="build/app/outputs/flutter-apk/app-debug.apk"
    OUTPUT_NAME="granivpn-debug-clean.apk"
fi

echo ""

# Проверка результата
echo "=== ✅ ПРОВЕРКА РЕЗУЛЬТАТА ==="
if [ ! -f "$APK_PATH" ]; then
    echo "❌ ОШИБКА: APK файл не найден: $APK_PATH"
    exit 1
fi

echo "APK найден: $APK_PATH"
ls -lh "$APK_PATH"
echo ""

# Проверка версии в APK
echo "Проверка версии в APK..."
TEMP_DIR=$(mktemp -d)
unzip -q -o "$APK_PATH" -d "$TEMP_DIR" 2>/dev/null

if strings "$TEMP_DIR/classes.dex" 2>/dev/null | grep -q "CODE_VERSION\|2026-01-15"; then
    echo "✅ Версия найдена в APK!"
    VERSION_IN_APK=$(strings "$TEMP_DIR/classes.dex" 2>/dev/null | grep -i "2026-01-15-v" | head -1)
    echo "   Версия в APK: $VERSION_IN_APK"
else
    echo "⚠️  ВНИМАНИЕ: Версия не найдена в classes.dex"
    echo "   Проверяю скомпилированные классы..."
    if find build/app -name "*VpnService*.class" -exec strings {} \; 2>/dev/null | grep -q "CODE_VERSION"; then
        echo "✅ Версия найдена в скомпилированных классах"
    else
        echo "❌ ОШИБКА: Версия НЕ найдена ни в APK, ни в классах!"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
fi

rm -rf "$TEMP_DIR"
echo ""

# Копирование в корень
echo "=== 📋 КОПИРОВАНИЕ APK ==="
cp "$APK_PATH" "/opt/grani/$OUTPUT_NAME"
chmod 644 "/opt/grani/$OUTPUT_NAME"
echo "✅ APK скопирован в: /opt/grani/$OUTPUT_NAME"
echo ""

# Итоговая информация
echo "=== 🎯 ИТОГОВАЯ ИНФОРМАЦИЯ ==="
echo "✅ APK успешно собран!"
echo ""
echo "📦 Файлы:"
echo "   • $APK_PATH"
echo "   • /opt/grani/$OUTPUT_NAME"
echo ""
echo "📊 Размер: $(ls -lh "$APK_PATH" | awk '{print $5}')"
echo "🔐 SHA1: $(sha1sum "$APK_PATH" | cut -d' ' -f1)"
echo "🕐 Время: $(stat -c "%y" "$APK_PATH" | cut -d'.' -f1)"
echo ""
echo "📱 Команды для установки:"
echo "   adb install -r /opt/grani/$OUTPUT_NAME"
echo ""
echo "🔍 Команды для проверки логов:"
echo "   adb logcat | grep -i 'GraniVpnService\\|CODE_VERSION\\|2026-01-15'"
echo ""
echo "✅ Готово!"

#!/bin/bash
# Скрипт для гарантированной чистой сборки APK
# Использование: ./clean_build.sh

set -e  # Остановка при ошибке

echo "🧹 Очистка кэша Flutter..."
cd /opt/grani/mobile-app
flutter clean

echo "🧹 Очистка кэша Gradle..."
cd android
./gradlew clean
cd ..

echo "🗑️  Удаление старого APK..."
rm -f build/app/outputs/flutter-apk/app-release.apk

echo "🔨 Сборка нового APK..."
flutter build apk --release --target-platform android-arm64

echo "✅ Проверка результата..."
if [ -f build/app/outputs/flutter-apk/app-release.apk ]; then
    SIZE=$(stat -c "%s" build/app/outputs/flutter-apk/app-release.apk)
    SIZE_MB=$(python3 -c "print(f'{${SIZE} / 1024 / 1024:.2f}')")
    MODIFY_TIME=$(stat -c "%y" build/app/outputs/flutter-apk/app-release.apk)
    
    # Получаем версию из pubspec.yaml
    VERSION=$(grep "^version:" pubspec.yaml | sed 's/version: //' | tr -d ' ')
    VERSION_NAME=$(echo $VERSION | cut -d'+' -f1)
    BUILD_NUMBER=$(echo $VERSION | cut -d'+' -f2)
    FULL_VERSION="${VERSION_NAME}+${BUILD_NUMBER}"
    BUILD_DATE=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Обновляем файл версии в корне проекта
    cat > /opt/grani/VERSION << EOF
# Версия сборки приложения GRANI VPN
# Автоматически обновляется при сборке APK

VERSION=${VERSION_NAME}
BUILD_NUMBER=${BUILD_NUMBER}
FULL_VERSION=${FULL_VERSION}
BUILD_DATE=${BUILD_DATE}
BUILD_TYPE=release
TARGET_PLATFORM=android-arm64
APK_SIZE=${SIZE_MB} MB
APK_PATH=mobile-app/build/app/outputs/flutter-apk/app-release.apk
EOF
    
    echo "✅ APK успешно собран!"
    echo "📦 Размер: ${SIZE_MB} MB (${SIZE} bytes)"
    echo "🕐 Время создания: ${MODIFY_TIME}"
    echo "📍 Путь: $(pwd)/build/app/outputs/flutter-apk/app-release.apk"
    echo "📝 Версия: ${FULL_VERSION}"
    echo "✅ Файл версии обновлен: /opt/grani/VERSION"
else
    echo "❌ Ошибка: APK не найден!"
    exit 1
fi

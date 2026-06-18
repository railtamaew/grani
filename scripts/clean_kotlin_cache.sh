#!/bin/bash
# Скрипт для очистки кэша Kotlin компилятора
# Использование: ./scripts/clean_kotlin_cache.sh

set -e

PROJECT_DIR="/opt/grani"
MOBILE_APP_DIR="$PROJECT_DIR/mobile-app"
ANDROID_DIR="$MOBILE_APP_DIR/android"

echo "🧹 Очистка кэша Kotlin компилятора..."

# Удаляем директорию с ошибками Kotlin
if [ -d "$ANDROID_DIR/.kotlin/errors" ]; then
    rm -rf "$ANDROID_DIR/.kotlin/errors"
    echo "✅ Удалена директория .kotlin/errors"
fi

# Очищаем build директорию
if [ -d "$ANDROID_DIR/build" ]; then
    rm -rf "$ANDROID_DIR/build"
    echo "✅ Очищена директория build"
fi

# Очищаем кэш Gradle (опционально, можно закомментировать если нужно сохранить зависимости)
if [ -d "$ANDROID_DIR/.gradle" ]; then
    read -p "Удалить кэш Gradle? Это заставит заново скачать зависимости. (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$ANDROID_DIR/.gradle"
        echo "✅ Очищен кэш Gradle"
    else
        echo "⏭️  Кэш Gradle сохранен"
    fi
fi

# Очищаем кэш Flutter
if [ -d "$MOBILE_APP_DIR/.dart_tool" ]; then
    rm -rf "$MOBILE_APP_DIR/.dart_tool"
    echo "✅ Очищен кэш Dart"
fi

echo ""
echo "✅ Очистка завершена!"
echo "Теперь можно запустить сборку: cd $MOBILE_APP_DIR && flutter clean && flutter pub get"


#!/bin/bash

# Скрипт автоматической сборки APK с автоинкрементом версии
# Использование: ./scripts/build_apk.sh [--version VERSION] [--build BUILD_NUMBER] [--clean]

set -e  # Остановка при ошибке

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PUBSPEC_FILE="$PROJECT_DIR/pubspec.yaml"
BUILD_LOG="$PROJECT_DIR/build_info.log"

cd "$PROJECT_DIR"

# Функция для логирования
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$BUILD_LOG"
}

# Функция для извлечения версии из pubspec.yaml
get_current_version() {
    local version_line=$(grep "^version:" "$PUBSPEC_FILE" | head -1)
    echo "$version_line" | sed -E 's/version:[[:space:]]*//'
}

# Функция для извлечения version name (до +)
get_version_name() {
    local full_version="$1"
    echo "$full_version" | cut -d'+' -f1
}

# Функция для извлечения build number (после +)
get_build_number() {
    local full_version="$1"
    if [[ "$full_version" == *"+"* ]]; then
        echo "$full_version" | cut -d'+' -f2
    else
        echo "1"
    fi
}

# Функция для обновления версии в pubspec.yaml
update_version() {
    local version_name="$1"
    local build_number="$2"
    local new_version="${version_name}+${build_number}"
    
    log "Обновление версии: $new_version"
    
    # Обновляем версию в pubspec.yaml
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        sed -i '' "s/^version:.*/version: $new_version/" "$PUBSPEC_FILE"
    else
        # Linux
        sed -i "s/^version:.*/version: $new_version/" "$PUBSPEC_FILE"
    fi
    
    log "✓ Версия обновлена в pubspec.yaml: $new_version"
}

# Функция для увеличения build number
increment_build_number() {
    local current_version=$(get_current_version)
    local version_name=$(get_version_name "$current_version")
    local build_number=$(get_build_number "$current_version")
    
    # Увеличиваем build number
    build_number=$((build_number + 1))
    
    update_version "$version_name" "$build_number"
    echo "${version_name}+${build_number}"
}

# Функция для увеличения patch версии (1.0.2 -> 1.0.3)
increment_patch_version() {
    local current_version=$(get_current_version)
    local version_name=$(get_version_name "$current_version")
    local build_number=$(get_build_number "$current_version")
    
    # Разбиваем version name на части
    IFS='.' read -ra VERSION_PARTS <<< "$version_name"
    local major=${VERSION_PARTS[0]}
    local minor=${VERSION_PARTS[1]}
    local patch=${VERSION_PARTS[2]}
    
    # Увеличиваем patch версию
    patch=$((patch + 1))
    build_number=$((build_number + 1))
    
    local new_version_name="${major}.${minor}.${patch}"
    update_version "$new_version_name" "$build_number"
    echo "${new_version_name}+${build_number}"
}

# Парсинг аргументов
CLEAN_BUILD=false
CUSTOM_VERSION=""
CUSTOM_BUILD=""
INCREMENT_PATCH=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --clean)
            CLEAN_BUILD=true
            shift
            ;;
        --version)
            CUSTOM_VERSION="$2"
            shift 2
            ;;
        --build)
            CUSTOM_BUILD="$2"
            shift 2
            ;;
        --patch)
            INCREMENT_PATCH=true
            shift
            ;;
        --help|-h)
            echo "Использование: $0 [опции]"
            echo ""
            echo "Опции:"
            echo "  --clean              Очистить проект перед сборкой"
            echo "  --version VERSION    Установить конкретную версию (например: 1.0.3)"
            echo "  --build NUMBER       Установить конкретный build number (например: 10)"
            echo "  --patch              Увеличить patch версию (1.0.2 -> 1.0.3)"
            echo "  --help, -h           Показать эту справку"
            echo ""
            echo "Примеры:"
            echo "  $0                    # Автоматически увеличить build number"
            echo "  $0 --patch             # Увеличить patch версию и build number"
            echo "  $0 --version 1.1.0    # Установить версию 1.1.0 (build number увеличится)"
            echo "  $0 --clean             # Очистить и собрать с автоинкрементом"
            exit 0
            ;;
        *)
            echo "Неизвестная опция: $1"
            echo "Используйте --help для справки"
            exit 1
            ;;
    esac
done

# Начало сборки
log "=========================================="
log "🚀 Начало сборки APK"
log "=========================================="

# Определяем новую версию
if [ -n "$CUSTOM_VERSION" ]; then
    # Пользователь указал версию
    if [ -n "$CUSTOM_BUILD" ]; then
        update_version "$CUSTOM_VERSION" "$CUSTOM_BUILD"
        NEW_VERSION="${CUSTOM_VERSION}+${CUSTOM_BUILD}"
    else
        local current_build=$(get_build_number "$(get_current_version)")
        local new_build=$((current_build + 1))
        update_version "$CUSTOM_VERSION" "$new_build"
        NEW_VERSION="${CUSTOM_VERSION}+${new_build}"
    fi
elif [ "$INCREMENT_PATCH" = true ]; then
    # Увеличиваем patch версию
    NEW_VERSION=$(increment_patch_version)
else
    # Автоматически увеличиваем build number
    NEW_VERSION=$(increment_build_number)
fi

log "📦 Новая версия: $NEW_VERSION"

# Синхронизация версий (pubspec -> local.properties + CODE_VERSION)
if [ -f "$PROJECT_DIR/scripts/sync_versions.sh" ]; then
    log "🔧 Синхронизация версий..."
    bash "$PROJECT_DIR/scripts/sync_versions.sh"
    log "✓ Синхронизация завершена"
fi

# Очистка проекта, если нужно
if [ "$CLEAN_BUILD" = true ]; then
    log "🧹 Очистка проекта..."
    flutter clean
    log "✓ Проект очищен"
fi

# Получение зависимостей
log "📥 Получение зависимостей..."
flutter pub get
log "✓ Зависимости получены"

# Сборка APK
log "🔨 Начало сборки APK (release)..."
BUILD_START=$(date +%s)

if flutter build apk --release; then
    BUILD_END=$(date +%s)
    BUILD_DURATION=$((BUILD_END - BUILD_START))
    
    APK_PATH="$PROJECT_DIR/build/app/outputs/flutter-apk/app-release.apk"
    
    if [ -f "$APK_PATH" ]; then
        APK_SIZE=$(du -h "$APK_PATH" | cut -f1)
        log "✅ Сборка успешно завершена!"
        log "📱 APK файл: $APK_PATH"
        log "📊 Размер: $APK_SIZE"
        log "⏱️  Время сборки: ${BUILD_DURATION} секунд"
        log "🏷️  Версия: $NEW_VERSION"
        
        # Сохраняем информацию о сборке
        echo "==========================================" >> "$BUILD_LOG"
        echo "Версия: $NEW_VERSION" >> "$BUILD_LOG"
        echo "Дата: $(date '+%Y-%m-%d %H:%M:%S')" >> "$BUILD_LOG"
        echo "Размер: $APK_SIZE" >> "$BUILD_LOG"
        echo "Путь: $APK_PATH" >> "$BUILD_LOG"
        echo "==========================================" >> "$BUILD_LOG"
        echo "" >> "$BUILD_LOG"
        
        log ""
        log "=========================================="
        log "✅ Сборка завершена успешно!"
        log "=========================================="
        log "Версия: $NEW_VERSION"
        log "Файл: $APK_PATH"
        log "Размер: $APK_SIZE"
        log ""
        
        exit 0
    else
        log "❌ ОШИБКА: APK файл не найден после сборки"
        exit 1
    fi
else
    log "❌ ОШИБКА: Сборка APK завершилась с ошибкой"
    exit 1
fi



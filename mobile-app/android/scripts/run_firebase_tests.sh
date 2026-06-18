#!/bin/bash

# Скрипт для запуска тестов в Firebase Test Lab
# Использование: ./scripts/run_firebase_tests.sh [--singbox-config FILE] [--wireguard-config FILE]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

SINGBOX_CONFIG=""
WIREGUARD_CONFIG=""
SINGBOX_B64=""
WIREGUARD_B64=""
DEVICE_MODEL="${DEVICE_MODEL:-Pixel2.arm}"
DEVICE_VERSION="${DEVICE_VERSION:-30}"

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
    case $1 in
        --singbox-config)
            SINGBOX_CONFIG="$2"
            shift 2
            ;;
        --wireguard-config)
            WIREGUARD_CONFIG="$2"
            shift 2
            ;;
        --singbox-b64)
            SINGBOX_B64="$2"
            shift 2
            ;;
        --wireguard-b64)
            WIREGUARD_B64="$2"
            shift 2
            ;;
        --device-model)
            DEVICE_MODEL="$2"
            shift 2
            ;;
        --device-version)
            DEVICE_VERSION="$2"
            shift 2
            ;;
        *)
            echo "❌ Неизвестный параметр: $1"
            echo ""
            echo "Использование:"
            echo "  $0 [--singbox-config FILE] [--wireguard-config FILE] [--device-model MODEL] [--device-version VERSION]"
            exit 1
            ;;
    esac
done

echo "🔥 Запуск тестов в Firebase Test Lab..."
echo ""

# Проверка установки gcloud
if ! command -v gcloud &> /dev/null; then
    echo "❌ Ошибка: gcloud CLI не установлен"
    echo "   Установите: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

# Проверка авторизации
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
    echo "❌ Ошибка: Не авторизован в gcloud"
    echo "   Выполните: gcloud auth login"
    exit 1
fi

# Проверка проекта Firebase
PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")
if [ -z "$PROJECT_ID" ]; then
    echo "❌ Ошибка: Проект Firebase не установлен"
    echo "   Выполните: gcloud config set project YOUR_PROJECT_ID"
    exit 1
fi

echo "✅ Проект: $PROJECT_ID"
echo "✅ Устройство: $DEVICE_MODEL, версия: $DEVICE_VERSION"
echo ""

# Проверка наличия APK (Flutter структура)
APP_APK="../build/app/outputs/apk/debug/app-debug.apk"
TEST_APK="../build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk"

# Альтернативные пути
if [ ! -f "$APP_APK" ]; then
    APP_APK="app/build/outputs/apk/debug/app-debug.apk"
fi

if [ ! -f "$TEST_APK" ]; then
    TEST_APK="app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
fi

if [ ! -f "$APP_APK" ]; then
    echo "⚠️  APK не найден, собираю..."
    ./gradlew :app:assembleDebug
    # Проверяем после сборки
    if [ -f "../build/app/outputs/apk/debug/app-debug.apk" ]; then
        APP_APK="../build/app/outputs/apk/debug/app-debug.apk"
    elif [ -f "app/build/outputs/apk/debug/app-debug.apk" ]; then
        APP_APK="app/build/outputs/apk/debug/app-debug.apk"
    fi
fi

if [ ! -f "$TEST_APK" ]; then
    echo "⚠️  Тестовый APK не найден, собираю..."
    ./gradlew :app:assembleDebugAndroidTest
    # Проверяем после сборки
    if [ -f "../build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk" ]; then
        TEST_APK="../build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
    elif [ -f "app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk" ]; then
        TEST_APK="app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
    fi
fi

# Финальная проверка
if [ ! -f "$APP_APK" ]; then
    echo "❌ Ошибка: Основной APK не найден после сборки"
    echo "   Ожидаемые пути:"
    echo "   - ../build/app/outputs/apk/debug/app-debug.apk"
    echo "   - app/build/outputs/apk/debug/app-debug.apk"
    exit 1
fi

if [ ! -f "$TEST_APK" ]; then
    echo "❌ Ошибка: Тестовый APK не найден после сборки"
    echo "   Ожидаемые пути:"
    echo "   - ../build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
    echo "   - app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
    exit 1
fi

# Подготовка конфигураций
# Включаем mock для VPN разрешения (Firebase Test Lab не может автоматически выдать разрешение)
ENV_VARS="clearPackageData=true,mock_vpn_permission=true"

if [ -n "$SINGBOX_CONFIG" ]; then
    if [ ! -f "$SINGBOX_CONFIG" ]; then
        echo "❌ Ошибка: Файл sing-box конфигурации не найден: $SINGBOX_CONFIG"
        exit 1
    fi
    SINGBOX_B64=$(base64 -w 0 < "$SINGBOX_CONFIG")
    ENV_VARS="$ENV_VARS,singbox_config_b64=$SINGBOX_B64"
    echo "✅ Sing-box конфигурация загружена"
    echo "   DEBUG: Base64 length: ${#SINGBOX_B64}"
    echo "   DEBUG: First 100 chars: ${SINGBOX_B64:0:100}..."
fi

if [ -n "$WIREGUARD_CONFIG" ]; then
    if [ ! -f "$WIREGUARD_CONFIG" ]; then
        echo "❌ Ошибка: Файл WireGuard конфигурации не найден: $WIREGUARD_CONFIG"
        exit 1
    fi
    WIREGUARD_B64=$(base64 -w 0 < "$WIREGUARD_CONFIG")
    ENV_VARS="$ENV_VARS,wireguard_config_b64=$WIREGUARD_B64"
    echo "✅ WireGuard конфигурация загружена"
    echo "   DEBUG: Base64 length: ${#WIREGUARD_B64}"
    echo "   DEBUG: First 100 chars: ${WIREGUARD_B64:0:100}..."
fi

if [ -n "$SINGBOX_B64" ]; then
    ENV_VARS="$ENV_VARS,singbox_config_b64=$SINGBOX_B64"
fi

if [ -n "$WIREGUARD_B64" ]; then
    ENV_VARS="$ENV_VARS,wireguard_config_b64=$WIREGUARD_B64"
fi

echo ""
echo "▶️  Загрузка APK и запуск тестов..."
echo ""

# Запуск тестов в Firebase Test Lab
gcloud firebase test android run \
    --type instrumentation \
    --app "$APP_APK" \
    --test "$TEST_APK" \
    --device model="$DEVICE_MODEL",version="$DEVICE_VERSION",locale=en,orientation=portrait \
    --environment-variables "$ENV_VARS" \
    --timeout 30m

TEST_RESULT=$?

if [ $TEST_RESULT -eq 0 ]; then
    echo ""
    echo "✅ Тесты завершены успешно!"
    echo ""
    echo "📊 Результаты доступны в Firebase Console:"
    echo "   https://console.firebase.google.com/project/$PROJECT_ID/testlab/histories"
else
    echo ""
    echo "❌ Тесты завершены с ошибками (код: $TEST_RESULT)"
    exit $TEST_RESULT
fi

#!/bin/bash

# Скрипт для настройки пользовательского аккаунта для Firebase Test Lab
# Использование: ./scripts/setup_user_account_firebase.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

PROJECT_ID="grani-479612"

echo "🔧 Настройка пользовательского аккаунта для Firebase Test Lab..."
echo ""

# Проверка gcloud
if ! command -v gcloud &> /dev/null; then
    echo "❌ Ошибка: gcloud CLI не установлен"
    echo "   Установите: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

# Шаг 1: Проверка текущего аккаунта
echo "📋 Шаг 1: Проверка текущего аккаунта..."
CURRENT_ACCOUNT=$(gcloud config get-value account 2>/dev/null || echo "")
echo "   Текущий аккаунт: $CURRENT_ACCOUNT"
echo ""

# Шаг 2: Выход из сервисного аккаунта (если используется)
if [[ "$CURRENT_ACCOUNT" == *".iam.gserviceaccount.com" ]]; then
    echo "⚠️  Обнаружен сервисный аккаунт: $CURRENT_ACCOUNT"
    echo "   Для работы с Firebase Test Lab рекомендуется использовать пользовательский аккаунт"
    echo ""
    read -p "   Выйти из сервисного аккаунта? (y/n): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "   Выход из сервисного аккаунта..."
        gcloud auth revoke "$CURRENT_ACCOUNT" 2>/dev/null || true
        echo "   ✅ Выполнено"
    else
        echo "   ⏭️  Пропущено"
    fi
    echo ""
fi

# Шаг 3: Авторизация пользовательским аккаунтом
echo "📋 Шаг 2: Авторизация пользовательским аккаунтом..."
echo "   Выполните одну из команд:"
echo ""
echo "   Вариант A (интерактивная авторизация):"
echo "     gcloud auth login"
echo ""
echo "   Вариант B (Application Default Credentials):"
echo "     gcloud auth application-default login"
echo ""
read -p "   Выполнить 'gcloud auth login' сейчас? (y/n): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "   Запуск интерактивной авторизации..."
    gcloud auth login
    echo "   ✅ Авторизация завершена"
else
    echo "   ⏭️  Пропущено. Выполните авторизацию вручную."
fi
echo ""

# Шаг 4: Настройка проекта
echo "📋 Шаг 3: Настройка проекта..."
CURRENT_PROJECT=$(gcloud config get-value project 2>/dev/null || echo "")
if [ "$CURRENT_PROJECT" != "$PROJECT_ID" ]; then
    echo "   Установка проекта: $PROJECT_ID"
    gcloud config set project "$PROJECT_ID"
    echo "   ✅ Проект установлен"
else
    echo "   ✅ Проект уже установлен: $PROJECT_ID"
fi
echo ""

# Шаг 5: Проверка доступа
echo "📋 Шаг 4: Проверка доступа..."
ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
if [ -z "$ACCOUNT" ]; then
    echo "   ❌ Ошибка: Не авторизован"
    echo "   Выполните: gcloud auth login"
    exit 1
fi

echo "   ✅ Аккаунт: $ACCOUNT"

# Проверка доступа к Firebase
if gcloud firebase projects list 2>/dev/null | grep -q "$PROJECT_ID"; then
    echo "   ✅ Доступ к Firebase подтвержден"
else
    echo "   ⚠️  Не удалось подтвердить доступ к Firebase"
    echo "   Убедитесь, что аккаунт имеет права доступа к проекту"
fi
echo ""

# Шаг 6: Проверка API
echo "📋 Шаг 5: Проверка включенных API..."
TESTING_API=$(gcloud services list --enabled --project="$PROJECT_ID" --filter="name:testing.googleapis.com" --format="value(name)" 2>/dev/null)
TOOLRESULTS_API=$(gcloud services list --enabled --project="$PROJECT_ID" --filter="name:toolresults.googleapis.com" --format="value(name)" 2>/dev/null)

if [ -n "$TESTING_API" ]; then
    echo "   ✅ Cloud Testing API включен"
else
    echo "   ⚠️  Cloud Testing API не включен"
    read -p "   Включить Cloud Testing API? (y/n): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        gcloud services enable testing.googleapis.com --project="$PROJECT_ID"
        echo "   ✅ API включен"
    fi
fi

if [ -n "$TOOLRESULTS_API" ]; then
    echo "   ✅ Tool Results API включен"
else
    echo "   ⚠️  Tool Results API не включен"
    read -p "   Включить Tool Results API? (y/n): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        gcloud services enable toolresults.googleapis.com --project="$PROJECT_ID"
        echo "   ✅ API включен"
    fi
fi
echo ""

# Шаг 7: Проверка APK
echo "📋 Шаг 6: Проверка APK..."
APP_APK="../build/app/outputs/apk/debug/app-debug.apk"
TEST_APK="../build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk"

if [ ! -f "$APP_APK" ]; then
    APP_APK="app/build/outputs/apk/debug/app-debug.apk"
fi

if [ ! -f "$TEST_APK" ]; then
    TEST_APK="app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
fi

if [ -f "$APP_APK" ]; then
    SIZE=$(du -h "$APP_APK" | cut -f1)
    echo "   ✅ Основной APK найден: $APP_APK ($SIZE)"
else
    echo "   ⚠️  Основной APK не найден"
    read -p "   Собрать APK? (y/n): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        ./gradlew :app:assembleDebug
        echo "   ✅ APK собран"
    fi
fi

if [ -f "$TEST_APK" ]; then
    SIZE=$(du -h "$TEST_APK" | cut -f1)
    echo "   ✅ Тестовый APK найден: $TEST_APK ($SIZE)"
else
    echo "   ⚠️  Тестовый APK не найден"
    read -p "   Собрать тестовый APK? (y/n): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        ./gradlew :app:assembleDebugAndroidTest
        echo "   ✅ Тестовый APK собран"
    fi
fi
echo ""

# Итоговая проверка
echo "📋 Итоговая проверка..."
echo ""
./scripts/check_firebase_setup.sh

echo ""
echo "✅ Настройка завершена!"
echo ""
echo "🚀 Для запуска тестов выполните:"
echo "   ./scripts/run_firebase_tests.sh \\"
echo "       --singbox-config test_configs/singbox_minimal.json \\"
echo "       --device-model Pixel2.arm \\"
echo "       --device-version 30"
echo ""

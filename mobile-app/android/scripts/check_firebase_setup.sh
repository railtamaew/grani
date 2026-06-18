#!/bin/bash

# Скрипт для проверки настройки Firebase Test Lab
# Использование: ./scripts/check_firebase_setup.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

echo "🔍 Проверка настройки Firebase Test Lab..."
echo ""

# Проверка gcloud
if ! command -v gcloud &> /dev/null; then
    echo "❌ gcloud CLI не установлен"
    exit 1
fi

# Получение проекта
PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")
if [ -z "$PROJECT_ID" ]; then
    echo "❌ Проект не установлен"
    exit 1
fi

echo "✅ Проект: $PROJECT_ID"
echo ""

# Проверка авторизации
ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
if [ -z "$ACCOUNT" ]; then
    echo "❌ Не авторизован в gcloud"
    exit 1
fi

echo "✅ Аккаунт: $ACCOUNT"
echo ""

# Проверка API
echo "📋 Проверка включенных API..."
TESTING_API=$(gcloud services list --enabled --project="$PROJECT_ID" --filter="name:testing.googleapis.com" --format="value(name)" 2>/dev/null)
TOOLRESULTS_API=$(gcloud services list --enabled --project="$PROJECT_ID" --filter="name:toolresults.googleapis.com" --format="value(name)" 2>/dev/null)

if [ -n "$TESTING_API" ]; then
    echo "✅ Cloud Testing API включен"
else
    echo "❌ Cloud Testing API не включен"
    echo "   Выполните: gcloud services enable testing.googleapis.com --project=$PROJECT_ID"
fi

if [ -n "$TOOLRESULTS_API" ]; then
    echo "✅ Tool Results API включен"
else
    echo "❌ Tool Results API не включен"
    echo "   Выполните: gcloud services enable toolresults.googleapis.com --project=$PROJECT_ID"
fi

echo ""

# Проверка ролей (если это сервисный аккаунт)
if [[ "$ACCOUNT" == *".iam.gserviceaccount.com" ]]; then
    echo "📋 Проверка ролей сервисного аккаунта..."
    ROLES=$(gcloud projects get-iam-policy "$PROJECT_ID" --flatten="bindings[].members" --format="value(bindings.role)" --filter="bindings.members:$ACCOUNT" 2>/dev/null)
    
    REQUIRED_ROLES=(
        "roles/cloudtestservice.testAdmin"
        "roles/storage.admin"
        "roles/firebase.sdkAdminServiceAgent"
    )
    
    for role in "${REQUIRED_ROLES[@]}"; do
        if echo "$ROLES" | grep -q "$role"; then
            echo "✅ Роль $role назначена"
        else
            echo "❌ Роль $role не назначена"
            echo "   Выполните: gcloud projects add-iam-policy-binding $PROJECT_ID --member='serviceAccount:$ACCOUNT' --role='$role'"
        fi
    done
else
    echo "ℹ️  Используется пользовательский аккаунт (не сервисный)"
    echo "   Для работы с Firebase Test Lab рекомендуется использовать сервисный аккаунт"
fi

echo ""

# Проверка APK
echo "📦 Проверка APK..."
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
    echo "✅ Основной APK найден: $APP_APK ($SIZE)"
else
    echo "❌ Основной APK не найден"
    echo "   Выполните: ./gradlew :app:assembleDebug"
fi

if [ -f "$TEST_APK" ]; then
    SIZE=$(du -h "$TEST_APK" | cut -f1)
    echo "✅ Тестовый APK найден: $TEST_APK ($SIZE)"
else
    echo "❌ Тестовый APK не найден"
    echo "   Выполните: ./gradlew :app:assembleDebugAndroidTest"
fi

echo ""
echo "✅ Проверка завершена"

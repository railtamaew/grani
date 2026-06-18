#!/bin/bash

# Скрипт-помощник для авторизации gcloud
# Использование: ./scripts/auth_helper.sh

set -e

echo "🔐 Помощник авторизации gcloud для Firebase Test Lab"
echo ""

# Проверка текущего состояния
CURRENT_ACCOUNT=$(gcloud config get-value account 2>/dev/null || echo "")
echo "Текущий аккаунт: $CURRENT_ACCOUNT"
echo ""

if [[ "$CURRENT_ACCOUNT" == *".iam.gserviceaccount.com" ]]; then
    echo "⚠️  Обнаружен сервисный аккаунт"
    echo "   Для Firebase Test Lab рекомендуется пользовательский аккаунт"
    echo ""
fi

echo "Выберите способ авторизации:"
echo "1) Интерактивная авторизация (откроет браузер)"
echo "2) Авторизация без браузера (покажет ссылку)"
echo "3) Использовать Application Default Credentials"
echo "4) Пропустить (использовать текущий аккаунт)"
echo ""
read -p "Ваш выбор (1-4): " choice

case $choice in
    1)
        echo ""
        echo "▶️  Запуск интерактивной авторизации..."
        echo "   Откроется браузер для авторизации"
        gcloud auth login
        ;;
    2)
        echo ""
        echo "▶️  Генерация ссылки для авторизации..."
        echo ""
        echo "Выполните следующую команду на машине с браузером:"
        echo ""
        TEMP_OUTPUT=$(gcloud auth login --no-browser 2>&1)
        echo "$TEMP_OUTPUT"
        echo ""
        echo "---"
        echo "Инструкция:"
        echo "1. Скопируйте команду выше (начинается с 'gcloud auth login --remote-bootstrap=...')"
        echo "2. Выполните её на машине с браузером (ваш MacBook)"
        echo "3. После авторизации скопируйте результат"
        echo "4. Вставьте результат в этот терминал"
        echo ""
        read -p "Вставьте результат авторизации: " auth_result
        if [ -n "$auth_result" ]; then
            echo "$auth_result" | gcloud auth login --no-browser --remote-bootstrap="$auth_result" 2>&1 || {
                echo "Попробуйте вставить только код авторизации в формате:"
                echo "state=XXX&code=YYY"
            }
        fi
        ;;
    3)
        echo ""
        echo "▶️  Настройка Application Default Credentials..."
        gcloud auth application-default login --no-browser
        echo ""
        echo "⚠️  Это также требует авторизации через браузер"
        ;;
    4)
        echo ""
        echo "⏭️  Использование текущего аккаунта: $CURRENT_ACCOUNT"
        ;;
    *)
        echo "❌ Неверный выбор"
        exit 1
        ;;
esac

echo ""
echo "✅ Проверка авторизации..."
gcloud auth list

echo ""
echo "✅ Проверка доступа к проекту..."
PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")
if [ -n "$PROJECT_ID" ]; then
    echo "   Проект: $PROJECT_ID"
    if gcloud firebase projects list 2>/dev/null | grep -q "$PROJECT_ID"; then
        echo "   ✅ Доступ к Firebase подтвержден"
    else
        echo "   ⚠️  Не удалось подтвердить доступ к Firebase"
    fi
fi

echo ""
echo "✅ Готово!"

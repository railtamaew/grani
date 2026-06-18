#!/bin/bash

# Скрипт для быстрого запуска unit-тестов
# Использование: ./RUN_TESTS.sh

set -e

cd "$(dirname "$0")"

echo "🧪 Запуск unit-тестов..."
echo ""

# Запуск тестов
./gradlew :app:testDebugUnitTest --rerun-tasks

echo ""
echo "✅ Тесты завершены!"
echo ""
echo "📊 Результаты:"
echo "  - Отчеты: app/build/test-results/testDebugUnitTest/"
echo "  - HTML отчет: app/build/reports/tests/testDebugUnitTest/index.html"
echo ""

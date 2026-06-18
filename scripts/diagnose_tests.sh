#!/usr/bin/env bash
# Скрипт диагностики падающих тестов
# Использование: /opt/grani/scripts/diagnose_tests.sh

set -euo pipefail

LOG_DIR="/opt/grani/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
ANDROID_TEST_LOG="${LOG_DIR}/android/test_diagnosis_${TIMESTAMP}.log"
FLUTTER_TEST_LOG="${LOG_DIR}/flutter/test_diagnosis_${TIMESTAMP}.log"

echo "=========================================="
echo "  Диагностика падающих тестов"
echo "=========================================="
echo ""

mkdir -p "$LOG_DIR/android" "$LOG_DIR/flutter"

# 1. Android тесты (таймаут 5 минут)
echo "[1/2] Запуск Android тестов с подробным логированием..."
cd /opt/grani/mobile-app/android

# Очистка предыдущих результатов
timeout 30 ./gradlew clean 2>&1 | tee -a "$ANDROID_TEST_LOG" || true

# Запуск тестов с подробным выводом (таймаут 5 минут)
timeout 300 ./gradlew connectedDebugAndroidTest \
  --info \
  --stacktrace 2>&1 | tee -a "$ANDROID_TEST_LOG" || {
    echo "⚠️  Тесты прерваны по таймауту или завершились с ошибкой"
}

echo ""
echo "   ✅ Android тесты выполнены"
echo "   📝 Логи: $ANDROID_TEST_LOG"

# 2. Flutter тесты (таймаут 2 минуты)
echo ""
echo "[2/2] Запуск Flutter тестов с подробным логированием..."
cd /opt/grani/mobile-app

timeout 120 flutter test \
  --verbose \
  --reporter expanded 2>&1 | tee "$FLUTTER_TEST_LOG" || {
    echo "⚠️  Тесты прерваны по таймауту или завершились с ошибкой"
}

echo ""
echo "   ✅ Flutter тесты выполнены"
echo "   📝 Логи: $FLUTTER_TEST_LOG"

# Анализ результатов
echo ""
echo "=========================================="
echo "  Анализ результатов"
echo "=========================================="
echo ""

# Android тесты
echo "Android тесты:"
if grep -q "BUILD SUCCESSFUL" "$ANDROID_TEST_LOG"; then
    echo "   ✅ BUILD SUCCESSFUL"
else
    echo "   ❌ BUILD FAILED или прерван"
fi

SKIPPED=$(grep -c "SKIPPED\|AssumptionViolatedException" "$ANDROID_TEST_LOG" 2>/dev/null || echo "0")
FAILED=$(grep -c "FAILED\|FAILURE" "$ANDROID_TEST_LOG" 2>/dev/null || echo "0")

echo "   Пропущено: $SKIPPED"
echo "   Упало: $FAILED"

if [ "$SKIPPED" -gt 0 ]; then
    echo ""
    echo "   ⚠️  Пропущенные тесты:"
    grep -A 3 "SKIPPED\|AssumptionViolatedException" "$ANDROID_TEST_LOG" 2>/dev/null | head -15 || true
fi

if [ "$FAILED" -gt 0 ]; then
    echo ""
    echo "   ❌ Упавшие тесты:"
    grep -A 5 "FAILED\|FAILURE" "$ANDROID_TEST_LOG" 2>/dev/null | head -20 || true
fi

# Flutter тесты
echo ""
echo "Flutter тесты:"
PASSED=$(grep -c "✓" "$FLUTTER_TEST_LOG" 2>/dev/null || echo "0")
FAILED_FLUTTER=$(grep -c "✗\|FAILED" "$FLUTTER_TEST_LOG" 2>/dev/null || echo "0")

echo "   Прошло: $PASSED"
echo "   Упало: $FAILED_FLUTTER"

if [ "$FAILED_FLUTTER" -gt 0 ]; then
    echo ""
    echo "   ❌ Упавшие тесты:"
    grep -A 5 "✗\|FAILED" "$FLUTTER_TEST_LOG" 2>/dev/null | head -20 || true
fi

echo ""
echo "=========================================="
echo "  Диагностика завершена"
echo "=========================================="
echo ""
echo "📝 Все логи сохранены:"
echo "   Android: $ANDROID_TEST_LOG"
echo "   Flutter: $FLUTTER_TEST_LOG"
echo ""

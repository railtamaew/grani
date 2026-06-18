#!/usr/bin/env bash
# Скрипт запуска тестов с UI поддержкой
# Использование: 
#   /opt/grani/scripts/run_test_with_ui.sh [test_name] [manual|auto]
#   test_name: integration, vpn_service, all, или путь к тесту
#   manual|auto: режим работы (по умолчанию manual)

set -euo pipefail

TEST_NAME="${1:-all}"
MODE="${2:-manual}"  # manual или auto

echo "=========================================="
echo "  Запуск тестов с UI поддержкой"
echo "  Тест: $TEST_NAME"
echo "  Режим: $MODE"
echo "=========================================="
echo ""

# Проверка запущенной системы
if ! pgrep -f "emulator.*grani_emulator" > /dev/null; then
    echo "Запуск системы тестирования..."
    /opt/grani/scripts/start_combined_testing.sh "$MODE"
    sleep 20
fi

# Установка APK (если нужно)
if [ "$TEST_NAME" != "skip_install" ]; then
    echo ""
    echo "Установка APK..."
    cd /opt/grani/mobile-app
    flutter install || {
        echo "⚠️  Не удалось установить через flutter install"
        echo "Попробуйте установить вручную через браузер (noVNC)"
    }
fi

# Запуск тестов
echo ""
echo "Запуск тестов..."
cd /opt/grani/mobile-app

case "$TEST_NAME" in
    "integration")
        flutter test test/integration/vpn_connection_flow_test.dart
        ;;
    "vpn_service")
        flutter test test/services/vpn_service_test.dart
        ;;
    "all")
        flutter test
        ;;
    *)
        if [ -f "$TEST_NAME" ]; then
            flutter test "$TEST_NAME"
        else
            echo "❌ Тест не найден: $TEST_NAME"
            exit 1
        fi
        ;;
esac

echo ""
echo "=========================================="
echo "  Тесты завершены"
echo "=========================================="
echo ""
echo "Проверьте логи в: /opt/grani/logs/android/"
echo ""

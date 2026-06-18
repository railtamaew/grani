#!/bin/bash
# Скрипт для отслеживания логов в реальном времени
# Использование: /opt/grani/scripts/tail_logs.sh [тип]

LOG_DIR="/opt/grani/logs"

# Типы логов
FLUTTER_LOG=$(ls -t $LOG_DIR/flutter_*.log 2>/dev/null | head -1)
LOGCAT_LOG=$(ls -t $LOG_DIR/logcat_*.log 2>/dev/null | head -1)
EMULATOR_LOG=$(ls -t $LOG_DIR/emulator_*.log 2>/dev/null | head -1)
COMBINED_LOG=$(ls -t $LOG_DIR/combined_*.log 2>/dev/null | head -1)

TYPE=${1:-"combined"}

case $TYPE in
    flutter)
        if [ -f "$FLUTTER_LOG" ]; then
            echo "Отслеживание Flutter логов: $FLUTTER_LOG"
            tail -f "$FLUTTER_LOG"
        else
            echo "Flutter лог не найден"
        fi
        ;;
    logcat)
        if [ -f "$LOGCAT_LOG" ]; then
            echo "Отслеживание Android Logcat: $LOGCAT_LOG"
            tail -f "$LOGCAT_LOG"
        else
            echo "Logcat лог не найден"
        fi
        ;;
    emulator)
        if [ -f "$EMULATOR_LOG" ]; then
            echo "Отслеживание логов эмулятора: $EMULATOR_LOG"
            tail -f "$EMULATOR_LOG"
        else
            echo "Лог эмулятора не найден"
        fi
        ;;
    combined|*)
        if [ -f "$COMBINED_LOG" ]; then
            echo "Отслеживание объединенных логов: $COMBINED_LOG"
            tail -f "$COMBINED_LOG"
        elif [ -f "$FLUTTER_LOG" ] && [ -f "$LOGCAT_LOG" ]; then
            echo "Отслеживание всех логов (Ctrl+C для выхода)..."
            tail -f "$FLUTTER_LOG" "$LOGCAT_LOG" 2>/dev/null
        else
            echo "Логи не найдены"
        fi
        ;;
esac



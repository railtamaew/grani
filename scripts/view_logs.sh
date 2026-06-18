#!/bin/bash
# Скрипт для просмотра логов разработки
# Использование: /opt/grani/scripts/view_logs.sh [тип] [количество строк]

LOG_DIR="/opt/grani/logs"

# Типы логов
FLUTTER_LOG=$(ls -t $LOG_DIR/flutter_*.log 2>/dev/null | head -1)
LOGCAT_LOG=$(ls -t $LOG_DIR/logcat_*.log 2>/dev/null | head -1)
EMULATOR_LOG=$(ls -t $LOG_DIR/emulator_*.log 2>/dev/null | head -1)
COMBINED_LOG=$(ls -t $LOG_DIR/combined_*.log 2>/dev/null | head -1)

TYPE=${1:-"all"}
LINES=${2:-50}

print_log() {
    local log_file=$1
    local log_name=$2
    
    if [ -f "$log_file" ]; then
        echo "=========================================="
        echo "  $log_name (последние $LINES строк)"
        echo "  Файл: $log_file"
        echo "=========================================="
        tail -n $LINES "$log_file"
        echo ""
    else
        echo "Лог не найден: $log_name"
        echo ""
    fi
}

case $TYPE in
    flutter)
        print_log "$FLUTTER_LOG" "Flutter Logs"
        ;;
    logcat)
        print_log "$LOGCAT_LOG" "Android Logcat"
        ;;
    emulator)
        print_log "$EMULATOR_LOG" "Emulator Logs"
        ;;
    combined)
        print_log "$COMBINED_LOG" "Combined Logs"
        ;;
    all|*)
        print_log "$FLUTTER_LOG" "Flutter Logs"
        print_log "$LOGCAT_LOG" "Android Logcat"
        print_log "$EMULATOR_LOG" "Emulator Logs"
        ;;
esac



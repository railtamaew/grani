#!/bin/bash
# Скрипт очистки для освобождения 10GB
# Использование: /opt/grani/scripts/cleanup_10gb.sh

set -euo pipefail

echo "=========================================="
echo "  Очистка для освобождения 10GB"
echo "=========================================="
echo ""

# Запоминаем начальное использование диска
INITIAL_USAGE=$(df -h / | tail -1 | awk '{print $3}')

# 1. Build артефакты
echo "[1/9] Очистка build артефактов..."
rm -rf /opt/grani/mobile-app/.dart_tool 2>/dev/null || true
rm -rf /opt/grani/mobile-app/.flutter-plugins* 2>/dev/null || true
rm -rf /opt/grani/mobile-app/.packages 2>/dev/null || true
rm -rf /opt/grani/mobile-app/build 2>/dev/null || true
rm -rf /opt/grani/mobile-app/android/.gradle 2>/dev/null || true
rm -rf /opt/grani/mobile-app/android/build 2>/dev/null || true
rm -rf /opt/grani/mobile-app/android/app/build 2>/dev/null || true
rm -rf /opt/grani/mobile-app/android/.kotlin 2>/dev/null || true
rm -rf ~/.kotlin 2>/dev/null || true
echo "   ✅ Build артефакты очищены"

# 2. Gradle глобальный кэш (большой!)
echo ""
echo "[2/9] Очистка Gradle кэша..."
rm -rf ~/.gradle/caches/transforms-* 2>/dev/null || true
rm -rf ~/.gradle/caches/modules-2/files-2.1/org.jetbrains.kotlin/ 2>/dev/null || true
echo "   ✅ Gradle кэш очищен"

# 3. Backups
echo ""
echo "[3/9] Очистка старых backups..."
rm -rf /opt/grani/backups/files_cleanup_20260104_002644 2>/dev/null || true
rm -rf /opt/grani/backups/cleanup_20260104_001323 2>/dev/null || true
rm -rf /opt/grani/backups/dependencies_20260104_002107 2>/dev/null || true
echo "   ✅ Backups очищены"

# 4. Логи
echo ""
echo "[4/9] Очистка старых логов..."
find /opt/grani/logs -name "*.log" -mtime +3 -delete 2>/dev/null || true
find /var/log -name "*.log" -mtime +7 -delete 2>/dev/null || true
rm -f /opt/android-sdk/emulator.log.* 2>/dev/null || true
echo "   ✅ Логи очищены"

# 5. Python кэш
echo ""
echo "[5/9] Очистка Python кэша..."
find /opt/grani/backend -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find /opt/grani -name "*.pyc" -delete 2>/dev/null || true
find /opt/grani -name "*.pyo" -delete 2>/dev/null || true
echo "   ✅ Python кэш очищен"

# 6. Node.js build
echo ""
echo "[6/9] Очистка Node.js build..."
rm -rf /opt/grani/admin-panel/build 2>/dev/null || true
rm -rf /opt/grani/admin-panel/.next 2>/dev/null || true
rm -rf /opt/grani/admin-panel/node_modules/.cache 2>/dev/null || true
echo "   ✅ Node.js build очищен"

# 7. Старые APK
echo ""
echo "[7/9] Очистка старых APK..."
find /opt/grani/release_apks -name "*.apk" -mtime +7 -delete 2>/dev/null || true
echo "   ✅ Старые APK удалены"

# 8. Временные файлы
echo ""
echo "[8/9] Очистка временных файлов..."
rm -rf /tmp/* 2>/dev/null || true
rm -rf /var/tmp/* 2>/dev/null || true
echo "   ✅ Временные файлы очищены"

# 9. Android SDK кэш (опционально)
echo ""
echo "[9/9] Очистка Android SDK кэша..."
rm -rf /opt/android-sdk/.android/cache 2>/dev/null || true
rm -rf /opt/android-sdk/.android/downloads 2>/dev/null || true
echo "   ✅ Android SDK кэш очищен"

# Финальное использование диска
FINAL_USAGE=$(df -h / | tail -1 | awk '{print $3}')
FINAL_FREE=$(df -h / | tail -1 | awk '{print $4}')

echo ""
echo "=========================================="
echo "  Очистка завершена!"
echo "=========================================="
echo ""
echo "Использование диска:"
echo "  Было: $INITIAL_USAGE"
echo "  Стало: $FINAL_USAGE"
echo "  Свободно: $FINAL_FREE"
echo ""
df -h / | tail -1
echo ""

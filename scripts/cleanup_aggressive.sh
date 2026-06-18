#!/bin/bash
# Агрессивная очистка для освобождения 10+ GB
# Использование: /opt/grani/scripts/cleanup_aggressive.sh

set -euo pipefail

echo "=========================================="
echo "  Агрессивная очистка для освобождения 10+ GB"
echo "=========================================="
echo ""

INITIAL_FREE=$(df -h / | tail -1 | awk '{print $4}')
INITIAL_USAGE=$(df -h / | tail -1 | awk '{print $3}')

# 1. Весь Gradle кэш (может быть 2-5GB!)
echo "[1/12] Очистка ВСЕГО Gradle кэша..."
rm -rf ~/.gradle/caches/* 2>/dev/null || true
rm -rf ~/.gradle/daemon 2>/dev/null || true
rm -rf ~/.gradle/wrapper 2>/dev/null || true
echo "   ✅ Gradle кэш полностью очищен"

# 2. Старый AVD grani_emulator (если не нужен)
echo ""
echo "[2/12] Удаление старого AVD grani_emulator..."
rm -rf /root/.android/avd/grani_emulator.avd 2>/dev/null || true
echo "   ✅ Старый AVD удален"

# 3. Android SDK кэш полностью
echo ""
echo "[3/12] Очистка Android SDK кэша полностью..."
rm -rf /opt/android-sdk/.android/* 2>/dev/null || true
rm -rf /opt/android-sdk/.cache 2>/dev/null || true
echo "   ✅ Android SDK кэш очищен"

# 4. Все backups (кроме последнего)
echo ""
echo "[4/12] Удаление старых backups..."
rm -rf /opt/grani/backups/cleanup_20260114_151702 2>/dev/null || true
rm -rf /opt/grani/backups/optimization_20260104_001741 2>/dev/null || true
rm -f /opt/grani/backups/*.tar.gz 2>/dev/null || true
echo "   ✅ Старые backups удалены"

# 5. Node modules (можно переустановить)
echo ""
echo "[5/12] Удаление node_modules (можно переустановить)..."
rm -rf /opt/grani/admin-panel/node_modules 2>/dev/null || true
echo "   ✅ node_modules удален (запустите: cd admin-panel && npm install)"

# 6. Flutter глобальный кэш
echo ""
echo "[6/12] Очистка Flutter глобального кэша..."
rm -rf ~/.pub-cache/hosted 2>/dev/null || true
rm -rf ~/.flutter 2>/dev/null || true
echo "   ✅ Flutter кэш очищен"

# 7. Системные пакеты кэш
echo ""
echo "[7/12] Очистка системных кэшей..."
apt-get clean 2>/dev/null || true
apt-get autoclean 2>/dev/null || true
rm -rf /var/cache/apt/archives/*.deb 2>/dev/null || true
echo "   ✅ Системные кэши очищены"

# 8. Docker (если установлен)
echo ""
echo "[8/12] Очистка Docker (если установлен)..."
docker system prune -af 2>/dev/null || true
docker volume prune -f 2>/dev/null || true
echo "   ✅ Docker очищен"

# 9. Старые логи системы
echo ""
echo "[9/12] Очистка системных логов..."
journalctl --vacuum-time=3d 2>/dev/null || true
rm -rf /var/log/*.gz 2>/dev/null || true
rm -rf /var/log/*.old 2>/dev/null || true
echo "   ✅ Системные логи очищены"

# 10. Build артефакты (повторно, на всякий случай)
echo ""
echo "[10/12] Повторная очистка build артефактов..."
rm -rf /opt/grani/mobile-app/.dart_tool 2>/dev/null || true
rm -rf /opt/grani/mobile-app/.flutter-plugins* 2>/dev/null || true
rm -rf /opt/grani/mobile-app/build 2>/dev/null || true
rm -rf /opt/grani/mobile-app/android/.gradle 2>/dev/null || true
rm -rf /opt/grani/mobile-app/android/build 2>/dev/null || true
echo "   ✅ Build артефакты очищены"

# 11. Все временные файлы
echo ""
echo "[11/12] Очистка всех временных файлов..."
rm -rf /tmp/* 2>/dev/null || true
rm -rf /var/tmp/* 2>/dev/null || true
rm -rf /root/.cache/* 2>/dev/null || true
echo "   ✅ Временные файлы очищены"

# 12. Старые APK (все кроме последних 2)
echo ""
echo "[12/12] Удаление старых APK..."
cd /opt/grani/release_apks 2>/dev/null && \
  ls -t *.apk 2>/dev/null | tail -n +3 | xargs rm -f 2>/dev/null || true
echo "   ✅ Старые APK удалены"

FINAL_FREE=$(df -h / | tail -1 | awk '{print $4}')
FINAL_USAGE=$(df -h / | tail -1 | awk '{print $3}')

echo ""
echo "=========================================="
echo "  Агрессивная очистка завершена!"
echo "=========================================="
echo ""
echo "Использование диска:"
echo "  Было использовано: $INITIAL_USAGE"
echo "  Стало использовано: $FINAL_USAGE"
echo "  Было свободно: $INITIAL_FREE"
echo "  Стало свободно: $FINAL_FREE"
echo ""
df -h / | tail -1
echo ""

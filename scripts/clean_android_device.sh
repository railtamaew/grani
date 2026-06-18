#!/bin/bash
# Скрипт для полной очистки следов приложения GRANI VPN с Android устройства через ADB

echo "=========================================="
echo "  ОЧИСТКА СЛЕДОВ GRANI VPN С УСТРОЙСТВА"
echo "=========================================="
echo ""

# Проверяем подключение устройства
if ! adb devices | grep -q "device$"; then
    echo "⚠️  Устройство не подключено через ADB"
    echo "   Подключите устройство и включите USB отладку"
    exit 1
fi

DEVICE_COUNT=$(adb devices | grep -c "device$")
echo "✅ Найдено устройств: $DEVICE_COUNT"
echo ""

# Пакеты для удаления
PACKAGES=("com.granivpn.mobile" "com.granivpn.mobile.debug")

echo "1. Удаление установленных пакетов..."
for PACKAGE in "${PACKAGES[@]}"; do
    if adb shell pm list packages | grep -q "$PACKAGE"; then
        echo "   Найден пакет: $PACKAGE"
        adb uninstall "$PACKAGE" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "   ✅ Удален: $PACKAGE"
        else
            echo "   ⚠️  Не удалось удалить: $PACKAGE (возможно уже удален)"
        fi
    else
        echo "   ℹ️  Пакет не найден: $PACKAGE"
    fi
done

echo ""
echo "2. Очистка данных приложения (если пакет все еще существует)..."
for PACKAGE in "${PACKAGES[@]}"; do
    # Пытаемся очистить данные приложения
    adb shell pm clear "$PACKAGE" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "   ✅ Данные очищены для: $PACKAGE"
    fi
done

echo ""
echo "3. Очистка остаточных файлов в /data/data/..."
# Очистка данных приложения напрямую (требует root)
for PACKAGE in "${PACKAGES[@]}"; do
    adb shell "su -c 'rm -rf /data/data/$PACKAGE'" 2>/dev/null && echo "   ✅ Очищено /data/data/$PACKAGE" || echo "   ℹ️  Нет доступа к /data/data/$PACKAGE (нужен root)"
done

echo ""
echo "4. Очистка кеша приложения..."
for PACKAGE in "${PACKAGES[@]}"; do
    adb shell "su -c 'rm -rf /data/dalvik-cache/profiles/$PACKAGE'" 2>/dev/null && echo "   ✅ Очищен кеш для: $PACKAGE" || echo "   ℹ️  Нет доступа к кешу (нужен root)"
done

echo ""
echo "5. Очистка файлов в /sdcard/Android/data/..."
for PACKAGE in "${PACKAGES[@]}"; do
    adb shell rm -rf /sdcard/Android/data/"$PACKAGE" 2>/dev/null && echo "   ✅ Очищено /sdcard/Android/data/$PACKAGE" || echo "   ℹ️  Нет файлов в /sdcard/Android/data/$PACKAGE"
    adb shell rm -rf /storage/emulated/0/Android/data/"$PACKAGE" 2>/dev/null && echo "   ✅ Очищено /storage/emulated/0/Android/data/$PACKAGE" || echo "   ℹ️  Нет файлов в /storage/emulated/0/Android/data/$PACKAGE"
done

echo ""
echo "6. Очистка файлов в /sdcard/Android/obb/..."
for PACKAGE in "${PACKAGES[@]}"; do
    adb shell rm -rf /sdcard/Android/obb/"$PACKAGE" 2>/dev/null && echo "   ✅ Очищено /sdcard/Android/obb/$PACKAGE" || echo "   ℹ️  Нет файлов в /sdcard/Android/obb/$PACKAGE"
    adb shell rm -rf /storage/emulated/0/Android/obb/"$PACKAGE" 2>/dev/null && echo "   ✅ Очищено /storage/emulated/0/Android/obb/$PACKAGE" || echo "   ℹ️  Нет файлов в /storage/emulated/0/Android/obb/$PACKAGE"
done

echo ""
echo "7. Финальная проверка..."
REMAINING=$(adb shell pm list packages | grep -c "granivpn" || echo "0")
if [ "$REMAINING" -gt 0 ]; then
    echo "⚠️  Все еще найдены пакеты granivpn:"
    adb shell pm list packages | grep "granivpn"
    echo ""
    echo "   Попробуйте вручную удалить через настройки устройства:"
    echo "   Настройки → Приложения → GRANI VPN → Удалить"
else
    echo "✅ Все пакеты удалены"
fi

echo ""
echo "=========================================="
echo "  ОЧИСТКА ЗАВЕРШЕНА"
echo "=========================================="
echo ""
echo "Теперь можно установить новую версию APK"

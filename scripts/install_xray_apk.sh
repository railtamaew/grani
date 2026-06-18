#!/bin/bash
# Скрипт для установки APK с поддержкой Xray протоколов

APK_PATH="/opt/grani/granivpn-release-xray.apk"

echo "=========================================="
echo "  Установка GRANI VPN APK (Xray)"
echo "=========================================="
echo ""

# Проверяем наличие APK
if [ ! -f "$APK_PATH" ]; then
    echo "❌ APK файл не найден: $APK_PATH"
    exit 1
fi

echo "✅ APK найден: $APK_PATH"
echo "📦 Размер: $(du -h "$APK_PATH" | cut -f1)"
echo ""

# Проверяем подключение устройства
echo "Проверка подключения устройства..."
if ! adb devices | grep -q "device$"; then
    echo "⚠️  Устройство не подключено через ADB"
    echo "   Подключите устройство и включите USB отладку"
    exit 1
fi

DEVICE_COUNT=$(adb devices | grep -c "device$")
echo "✅ Найдено устройств: $DEVICE_COUNT"
echo ""

# Удаляем все возможные версии приложения
echo "Удаление всех версий приложения..."
PACKAGES=("com.granivpn.mobile" "com.granivpn.mobile.debug")

for PACKAGE in "${PACKAGES[@]}"; do
    if adb shell pm list packages | grep -q "$PACKAGE"; then
        echo "⚠️  Найдена установленная версия: $PACKAGE"
        echo "   Удаляем..."
        
        # Пытаемся удалить обычным способом
        adb uninstall "$PACKAGE" 2>/dev/null
        
        if [ $? -eq 0 ]; then
            echo "✅ Удалено: $PACKAGE"
        else
            # Пытаемся удалить через shell pm uninstall
            echo "   Пробуем альтернативный способ..."
            adb shell pm uninstall "$PACKAGE" 2>/dev/null
            if [ $? -eq 0 ]; then
                echo "✅ Удалено: $PACKAGE"
            else
                echo "⚠️  Не удалось удалить: $PACKAGE"
                echo "   Возможно требуется ручное удаление через настройки устройства"
            fi
        fi
        echo ""
    fi
done

# Проверяем, что все пакеты удалены
echo "Финальная проверка..."
REMAINING=$(adb shell pm list packages | grep -c "granivpn" || echo "0")
if [ "$REMAINING" -gt 0 ]; then
    echo "⚠️  Все еще найдены пакеты granivpn на устройстве"
    echo "   Список пакетов:"
    adb shell pm list packages | grep "granivpn"
    echo ""
    echo "❌ Пожалуйста, удалите приложение вручную через настройки устройства"
    echo "   Настройки → Приложения → GRANI VPN → Удалить"
    exit 1
fi

echo "✅ Все версии приложения удалены"
echo ""

# Устанавливаем новую версию
echo "Установка новой версии..."
adb install "$APK_PATH"

if [ $? -eq 0 ]; then
    echo ""
    echo "=========================================="
    echo "  ✅ УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!"
    echo "=========================================="
    echo ""
    echo "📱 APK установлен на устройство"
    echo "🚀 Можно запускать приложение и тестировать Xray протоколы:"
    echo "   - VLESS"
    echo "   - VMESS"
    echo "   - REALITY"
    echo ""
else
    echo ""
    echo "❌ Ошибка установки APK"
    echo ""
    echo "Возможные причины:"
    echo "  - Устройство не разрешило установку из неизвестных источников"
    echo "  - Недостаточно места на устройстве"
    echo "  - Конфликт с другой версией приложения"
    echo ""
    echo "Попробуйте:"
    echo "  1. Разрешить установку из неизвестных источников"
    echo "  2. Удалить старую версию вручную: adb uninstall $PACKAGE_NAME"
    echo "  3. Установить вручную: adb install $APK_PATH"
    exit 1
fi
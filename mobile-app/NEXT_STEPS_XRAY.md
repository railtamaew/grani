# Следующие шаги для завершения интеграции XRay-core

## Текущее состояние

✅ **Выполнено:**
1. Библиотеки XRay-core собраны и добавлены в `jniLibs/`
2. Структура проекта готова
3. JNI обертка создана (`XrayCoreJni.kt`)
4. Парсер конфигураций готов (`XrayConfigParser.kt`)
5. VpnService.kt расширен для поддержки XRay
6. Flutter код обновлен для передачи JSON конфигурации

⚠️ **Требуется:**
- Адаптация кода для использования libXray Java API
- Интеграция готовых классов libXray вместо прямых JNI вызовов

## План действий

### Шаг 1: Добавить libXray AAR как зависимость

**Файл:** `android/app/build.gradle`

```gradle
dependencies {
    implementation "org.jetbrains.kotlin:kotlin-stdlib:$kotlin_version"
    // Добавить libXray AAR
    implementation files('libs/libXray.aar')
}
```

**Действия:**
1. Скопировать `libXray.aar` в `android/app/libs/`
2. Обновить `build.gradle`

### Шаг 2: Создать обертку для libXray Java API

**Новый файл:** `android/app/src/main/kotlin/com/granivpn/mobile/XrayLibWrapper.kt`

**Функциональность:**
- Использовать классы `libXray.LibXray`, `libXray.RunXrayRequest` и др.
- Обернуть вызовы в удобный интерфейс
- Интегрировать с существующим `VpnService.kt`

### Шаг 3: Обновить VpnService.kt

**Изменения:**
- Заменить вызовы `XrayCoreJni` на `XrayLibWrapper`
- Использовать `libXray.LibXray.runXrayFromJSON()` для запуска XRay
- Настроить обработку пакетов через libXray

### Шаг 4: Обновить XrayCoreJni.kt (опционально)

**Варианты:**
- **Вариант A:** Удалить `XrayCoreJni.kt` и использовать только `XrayLibWrapper`
- **Вариант B:** Оставить как fallback и использовать `XrayLibWrapper` как основной

### Шаг 5: Тестирование

1. **Сборка APK:**
   ```bash
   cd /opt/grani/mobile-app
   flutter build apk --release
   ```

2. **Проверка загрузки библиотеки:**
   - Установить APK на устройство
   - Проверить логи: `adb logcat | grep -E "Xray|libXray|GraniVpnService"`

3. **Тестирование подключения:**
   - Выбрать сервер с поддержкой XRay
   - Выбрать протокол VLESS/VMESS
   - Попытаться подключиться
   - Проверить логи на наличие ошибок

## Детальный план реализации

### 1. Копирование AAR файла

```bash
mkdir -p /opt/grani/mobile-app/android/app/libs
cp /tmp/libXray/libXray.aar /opt/grani/mobile-app/android/app/libs/
```

### 2. Создание XrayLibWrapper.kt

Основные методы:
- `init()` - инициализация libXray
- `startXray(configJson: String)` - запуск XRay с JSON конфигурацией
- `stopXray()` - остановка XRay
- `isRunning()` - проверка статуса
- `getDialerController()` - получение контроллера для VPN интерфейса

### 3. Интеграция в VpnService.kt

В методе `processXrayPackets`:
- Инициализировать libXray
- Запустить XRay с JSON конфигурацией
- Настроить VPN интерфейс для маршрутизации трафика
- Обрабатывать пакеты через libXray

### 4. Обработка ошибок

- Добавить обработку ошибок инициализации
- Логирование всех операций
- Graceful shutdown при ошибках

## Приоритет задач

**Высокий приоритет:**
1. ✅ Добавить AAR в зависимости
2. ✅ Создать XrayLibWrapper
3. ✅ Обновить VpnService.kt

**Средний приоритет:**
4. Тестирование загрузки библиотеки
5. Тестирование подключения

**Низкий приоритет:**
6. Оптимизация производительности
7. Дополнительные функции (статистика, логи)

## Ожидаемые проблемы и решения

### Проблема 1: Конфликт имен библиотек
**Решение:** libXray использует `libgojni.so`, но мы скопировали как `libxray.so`. Нужно либо переименовать обратно, либо использовать AAR (который содержит правильные имена).

### Проблема 2: Несовместимость API
**Решение:** libXray может требовать другую структуру конфигурации. Нужно адаптировать `XrayConfig.toFullJsonConfig()` под требования libXray.

### Проблема 3: VPN интерфейс
**Решение:** libXray может требовать специальной настройки VPN интерфейса. Нужно интегрировать с `DialerController` из libXray.

## Полезные ресурсы

- Документация libXray: https://github.com/XTLS/libXray
- Примеры использования: проверить тесты в репозитории libXray
- API документация: извлечь из AAR или посмотреть исходники

## Время выполнения

- Шаг 1: 5 минут
- Шаг 2: 30-60 минут
- Шаг 3: 30-60 минут
- Шаг 4: 15-30 минут
- Шаг 5: 1-2 часа (тестирование)

**Общее время:** 2-4 часа



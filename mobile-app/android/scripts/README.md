# Скрипты для автоматизации тестирования Android

Этот набор скриптов предназначен для автоматизации тестирования VPN сервиса на реальных Android устройствах.

## Предварительные требования

1. **ADB установлен и настроен**
   ```bash
   adb devices  # Должно показать подключенное устройство
   ```

2. **Устройство подключено и авторизовано**
   - Включена отладка по USB
   - Разрешен доступ к устройству

3. **VPN разрешение выдано вручную**
   - При первом запуске приложения подтвердите VPN разрешение
   - Или используйте: `adb shell pm grant com.granivpn.mobile android.permission.BIND_VPN_SERVICE`

## Скрипты

### 1. `install_apk.sh` - Установка APK на устройство

Устанавливает основное приложение и тестовое APK на подключенное устройство.

```bash
cd /opt/grani/mobile-app/android
./scripts/install_apk.sh
```

**Что делает:**
- Проверяет подключение устройства
- Устанавливает `app-debug.apk` (основное приложение)
- Устанавливает `app-debug-androidTest.apk` (тестовое приложение)
- Собирает APK, если они не найдены

### 2. `generate_test_configs.sh` - Генерация тестовых конфигов

Создает примеры конфигураций для тестирования.

```bash
cd /opt/grani/mobile-app/android
./scripts/generate_test_configs.sh [--output-dir DIR]
```

**Создает:**
- `singbox_minimal.json` - минимальный sing-box конфиг
- `singbox_vless_example.json` - пример с VLESS
- `wireguard_example.conf` - пример WireGuard конфига
- `encode_configs.sh` - скрипт для кодирования в base64

**Использование:**
```bash
# Генерация конфигов
./scripts/generate_test_configs.sh

# Редактирование конфигов (замените placeholder значения)
cd test_configs
nano singbox_minimal.json

# Кодирование в base64
./encode_configs.sh
```

### 3. `run_singbox_test.sh` - Запуск sing-box теста

Запускает тест `start_singbox_with_provided_config` с указанной конфигурацией.

```bash
cd /opt/grani/mobile-app/android

# Из файла
./scripts/run_singbox_test.sh test_configs/singbox_minimal.json

# Или base64 строка
./scripts/run_singbox_test.sh --b64 "eyJsb2c..."
```

**Что делает:**
- Проверяет подключение устройства
- Устанавливает APK, если нужно
- Кодирует конфиг в base64 (если передан файл)
- Запускает тест через `am instrument`

### 4. `run_wireguard_test.sh` - Запуск WireGuard теста

Запускает тест `start_wireguard_with_provided_config` с указанной конфигурацией.

```bash
cd /opt/grani/mobile-app/android

# Из файла
./scripts/run_wireguard_test.sh test_configs/wireguard_example.conf

# Или base64 строка
./scripts/run_wireguard_test.sh --b64 "W0ludGVyZmFjZQ..."
```

### 5. `run_all_tests.sh` - Полный прогон AndroidTest

Запускает все инструментальные тесты через Gradle с параметрами.

```bash
cd /opt/grani/mobile-app/android

# С конфигами из файлов
./scripts/run_all_tests.sh \
    --singbox-config test_configs/singbox_minimal.json \
    --wireguard-config test_configs/wireguard_example.conf

# С base64 строками
./scripts/run_all_tests.sh \
    --singbox-b64 "eyJsb2c..." \
    --wireguard-b64 "W0ludGVyZmFjZQ..."
```

**Результаты:**
- HTML отчет: `app/build/app/reports/androidTests/connected/debug/index.html`
- XML результаты: `app/build/app/outputs/androidTest-results/connected/debug/`

## Пример полного цикла тестирования

```bash
cd /opt/grani/mobile-app/android

# 1. Генерация тестовых конфигов
./scripts/generate_test_configs.sh

# 2. Редактирование конфигов (замените placeholder значения реальными)
cd test_configs
# ... редактирование ...

# 3. Установка APK на устройство
cd ..
./scripts/install_apk.sh

# 4. Выдача VPN разрешения (вручную на устройстве или через adb)
adb shell pm grant com.granivpn.mobile android.permission.BIND_VPN_SERVICE

# 5. Запуск отдельных тестов
./scripts/run_singbox_test.sh test_configs/singbox_minimal.json
./scripts/run_wireguard_test.sh test_configs/wireguard_example.conf

# 6. Полный прогон всех тестов
./scripts/run_all_tests.sh \
    --singbox-config test_configs/singbox_minimal.json \
    --wireguard-config test_configs/wireguard_example.conf
```

## Устранение проблем

### Устройство не найдено
```bash
# Проверьте подключение
adb devices

# Перезапустите adb сервер
adb kill-server
adb start-server
```

### VPN разрешение не выдано
```bash
# Выдача через adb
adb shell pm grant com.granivpn.mobile android.permission.BIND_VPN_SERVICE

# Или вручную на устройстве:
# Настройки → Приложения → GraniVPN → Разрешения → VPN
```

### Тесты падают с таймаутом
- Увеличьте таймаут в тестах (по умолчанию 10 секунд)
- Проверьте, что конфигурация корректна
- Убедитесь, что VPN разрешение выдано

## Firebase Test Lab

Для запуска тестов в Firebase Test Lab см. `run_firebase_tests.sh` (требуется настройка прав доступа).

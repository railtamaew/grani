# Создание валидных тестовых конфигураций

**Дата:** 2026-01-20  
**Статус:** ✅ Выполнено

---

## Что было сделано

### 1. Создан скрипт генерации валидных конфигураций

**Файл:** `/opt/grani/mobile-app/android/scripts/generate_valid_test_configs.sh`

**Функции:**
- ✅ Генерирует валидные WireGuard ключи (приватный и публичный)
- ✅ Создает валидную WireGuard конфигурацию
- ✅ Создает валидную sing-box конфигурацию
- ✅ Сохраняет ключи сервера для справки
- ✅ Создает документацию

### 2. Созданы валидные конфигурации

**WireGuard:**
- ✅ `wireguard_valid.conf` - валидная конфигурация с реальными ключами
- ✅ `wireguard_server_keys.txt` - ключи сервера (для справки)

**Sing-box:**
- ✅ `singbox_valid.json` - минимальная валидная конфигурация (создает TUN интерфейс)
- ✅ `singbox_vless_valid.json` - пример с VLESS (требует реальный сервер)

**Документация:**
- ✅ `README_VALID_CONFIGS.md` - инструкция по использованию

---

## Что нужно для использования

### 1. Для WireGuard тестов

**Текущая конфигурация:**
- ✅ Валидные ключи (сгенерированы автоматически)
- ⚠️  Endpoint = 127.0.0.1:51820 (localhost)

**Ограничения:**
- Конфигурация валидна для парсинга и проверки ключей
- Не создаст реальное подключение (нет сервера на localhost)
- Для реального подключения нужен реальный WireGuard сервер

**Варианты:**
1. **Использовать как есть** - тесты проверят парсинг и создание интерфейса
2. **Заменить endpoint** - указать IP реального тестового сервера
3. **Mock WireGuard библиотеку** - для тестирования только логики приложения

### 2. Для Sing-box тестов

**Текущая конфигурация:**
- ✅ Валидная JSON структура
- ✅ Создает TUN интерфейс
- ⚠️  Использует 'direct' outbound (локальное подключение)

**Ограничения:**
- Создаст VPN интерфейс (TUN)
- Не создаст реальное VPN подключение к серверу
- Подходит для тестирования создания интерфейса и парсинга

**Варианты:**
1. **Использовать как есть** - тесты проверят создание интерфейса
2. **Добавить реальный outbound** - для тестирования реального подключения
3. **Mock sing-box** - для тестирования только логики приложения

---

## Использование в тестах

### Firebase Test Lab

```bash
cd /opt/grani/mobile-app/android

./scripts/run_firebase_tests.sh \
  --singbox-config test_configs/singbox_valid.json \
  --wireguard-config test_configs/wireguard_valid.conf \
  --device-model Pixel2.arm \
  --device-version 30
```

### Локальные тесты

```bash
cd /opt/grani/mobile-app/android

./gradlew connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.singbox_config_b64=$(base64 -w 0 < test_configs/singbox_valid.json) \
  -Pandroid.testInstrumentationRunnerArguments.wireguard_config_b64=$(base64 -w 0 < test_configs/wireguard_valid.conf)
```

---

## Ожидаемые результаты

### WireGuard тесты

**С валидными ключами:**
- ✅ Парсинг конфигурации пройдет успешно
- ✅ Ключи будут валидными (не KeyFormatException)
- ⚠️  Подключение может не установиться (нет сервера на localhost)
- ✅ VPN интерфейс может быть создан (если библиотека поддерживает)

**Что проверить:**
- Парсинг конфигурации
- Валидация ключей
- Создание VPN интерфейса (если возможно без сервера)

### Sing-box тесты

**С валидной конфигурацией:**
- ✅ Парсинг JSON пройдет успешно
- ✅ Валидация конфигурации пройдет
- ✅ TUN интерфейс будет создан
- ⚠️  Реальное подключение не установится (direct outbound)

**Что проверить:**
- Парсинг конфигурации
- Валидация JSON
- Создание TUN интерфейса
- Проверка трафика (может быть минимальный из-за direct outbound)

---

## Следующие шаги

### 1. Запустить тесты с валидными конфигурациями

```bash
cd /opt/grani/mobile-app/android
./scripts/run_firebase_tests.sh \
  --singbox-config test_configs/singbox_valid.json \
  --wireguard-config test_configs/wireguard_valid.conf
```

**Ожидаемый результат:**
- Тесты не должны падать с KeyFormatException
- VPN интерфейсы должны создаваться
- Проверка трафика может показать минимальные значения (из-за отсутствия реального сервера)

### 2. Если нужны реальные подключения

**Для WireGuard:**
- Настроить тестовый WireGuard сервер
- Заменить endpoint в конфигурации на IP сервера
- Убедиться, что сервер использует публичный ключ из `wireguard_server_keys.txt`

**Для Sing-box:**
- Добавить валидный outbound (vless/vmess) с реальным сервером
- Указать валидный UUID и сервер
- Настроить TLS (если требуется)

### 3. Альтернатива: разделить тесты

**Unit тесты (парсинг):**
- Использовать валидные конфигурации
- Проверять только парсинг и валидацию
- Не требовать реального подключения

**Integration тесты (подключение):**
- Использовать реальные серверы
- Проверять реальное VPN подключение
- Требовать валидные конфигурации с реальными серверами

---

## Файлы

**Скрипт:**
- `/opt/grani/mobile-app/android/scripts/generate_valid_test_configs.sh`

**Конфигурации:**
- `/opt/grani/mobile-app/android/test_configs/wireguard_valid.conf`
- `/opt/grani/mobile-app/android/test_configs/wireguard_server_keys.txt`
- `/opt/grani/mobile-app/android/test_configs/singbox_valid.json`
- `/opt/grani/mobile-app/android/test_configs/singbox_vless_valid.json`
- `/opt/grani/mobile-app/android/test_configs/README_VALID_CONFIGS.md`

---

## Заключение

✅ Валидные тестовые конфигурации созданы  
✅ WireGuard ключи сгенерированы  
✅ Sing-box конфигурации валидны  
✅ Готовы к использованию в тестах

⚠️  **Ограничения:**
- WireGuard конфигурация использует localhost (нет реального сервера)
- Sing-box конфигурация использует direct outbound (нет реального подключения)

💡 **Рекомендация:**
- Использовать для тестирования парсинга и создания интерфейсов
- Для реального подключения нужны реальные серверы или mock библиотеки

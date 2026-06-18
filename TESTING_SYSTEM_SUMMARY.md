# 🧪 Система тестирования перед сборкой APK

## ✅ Что создано

### 1. Тесты sing-box конфигураций
- **`scripts/test_singbox_config.py`** - Генерация и валидация конфигураций
- **`scripts/test_singbox_docker.sh`** - Валидация через Docker
- **`backend/tests/test_singbox_config_format.py`** - Unit-тесты формата

**Что проверяется:**
- ✅ Правильный формат (без `settings.vnext`, с `server`/`server_port`)
- ✅ DNS формат (объекты `{"address": "..."}`, не строки)
- ✅ TUN inbound (без `dns_address`, `inet4_route`)
- ✅ TLS/Reality формат (`tls.reality`, не `stream_settings.reality_settings`)

### 2. Тесты протоколов VPN
- **`scripts/test_protocols.py`** - Тестирование всех протоколов
- **`backend/tests/test_protocols.py`** - Unit-тесты протоколов

**Что проверяется:**
- ✅ API значения протоколов (`wireguard`, `xray_vless`, и т.д.)
- ✅ Определение протокола (VLESS vs VMESS)
- ✅ Форматы конфигураций (Xray, WireGuard)
- ✅ Структура `supported_protocols` сервера

### 3. Тесты device_id
- **`scripts/test_device_id.py`** - Тестирование механизма device_id
- **`backend/tests/test_device_id.py`** - Unit-тесты device_id

**Что проверяется:**
- ✅ Регистрация устройства (200 при первой, 409 при повторной)
- ✅ Отправка логов (200 для зарегистрированного, 404 для незарегистрированного)
- ✅ Повторная регистрация при 404
- ✅ Формат device_id (валидация)
- ✅ Таймауты регистрации (30 секунд)

### 4. Объединенные скрипты
- **`scripts/test_all.py`** - Запуск всех тестов (Python)
- **`scripts/RUN_ALL_TESTS.sh`** - Запуск всех тестов (Bash)

### 5. Документация
- **`docs/TESTING_SINGBOX_CONFIG.md`** - Документация по sing-box
- **`docs/TESTING_PROTOCOLS_AND_DEVICE_ID.md`** - Документация по протоколам и device_id
- **`scripts/QUICK_START_TESTING.md`** - Быстрый старт
- **`scripts/QUICK_TEST.md`** - Краткая инструкция

## 🚀 Использование

### Все тесты сразу

```bash
# Python версия
python3 scripts/test_all.py

# Bash версия
./scripts/RUN_ALL_TESTS.sh
```

### Отдельные тесты

```bash
# Sing-box конфигурации
python3 scripts/test_singbox_config.py --validate-only
python3 scripts/test_singbox_config.py --docker

# Протоколы
python3 scripts/test_protocols.py
python3 scripts/test_protocols.py --protocol wireguard

# Device ID
python3 scripts/test_device_id.py
python3 scripts/test_device_id.py --scenario register
```

## 📋 Workflow перед сборкой APK

```
1. Изменение логики в Python-скриптах
   ↓
2. Запуск тестов: python3 scripts/test_all.py
   ↓
3. Если все тесты прошли → перенос в мобильное приложение
   ↓
4. Сборка APK: cd mobile-app && flutter build apk --debug
   ↓
5. Тестирование на устройстве
```

## ✅ Преимущества

- ⚡ **Быстро**: Тестирование за секунды (без сборки APK)
- 🐛 **Раннее обнаружение**: Нахождение ошибок до сборки
- 🔄 **Регрессионные тесты**: Проверка разных сценариев
- 📖 **Документировано**: Полная документация процесса
- 🎯 **Фокус**: Тестируем логику, а не сборку

## 📊 Статистика

- **Скриптов тестирования**: 6
- **Unit-тестов**: 3 файла
- **Документации**: 4 файла
- **Покрытие**: sing-box, протоколы, device_id

## 🎯 Следующие шаги

1. **Протестируйте текущую конфигурацию:**
   ```bash
   python3 scripts/test_all.py
   ```

2. **Исправьте формат в Python-скриптах** (если нужно)

3. **После успешных тестов перенесите изменения в мобильное приложение**

4. **Соберите APK только после успешных тестов**

## 📖 Дополнительная информация

- Подробная документация: `docs/TESTING_SINGBOX_CONFIG.md`
- Быстрый старт: `scripts/QUICK_START_TESTING.md`
- Краткая инструкция: `scripts/QUICK_TEST.md`

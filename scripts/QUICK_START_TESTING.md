# 🚀 Быстрый старт: Тестирование перед сборкой APK

## Все тесты одной командой

```bash
# Запуск всех тестов (sing-box, протоколы, device_id)
python3 scripts/test_all.py
```

## Отдельные тесты

### 1. Sing-box конфигурации
```bash
# Проверка формата (быстро)
python3 scripts/test_singbox_config.py --validate-only

# Полная валидация через Docker
python3 scripts/test_singbox_config.py --docker
```

### 2. Протоколы VPN
```bash
# Все протоколы
python3 scripts/test_protocols.py

# Только WireGuard
python3 scripts/test_protocols.py --protocol wireguard

# Только Xray
python3 scripts/test_protocols.py --protocol xray
```

### 3. Device ID
```bash
# Все сценарии
python3 scripts/test_device_id.py

# Только регистрация
python3 scripts/test_device_id.py --scenario register

# Только логи
python3 scripts/test_device_id.py --scenario logs
```

## Workflow перед сборкой APK

```bash
# 1. Все тесты
python3 scripts/test_all.py

# 2. Если все прошло, собирайте APK
cd mobile-app && flutter build apk --debug
```

## Что проверяется

✅ **Sing-box конфигурации:**
- Правильный формат (без settings.vnext)
- Валидность через sing-box CLI/Docker

✅ **Протоколы:**
- API значения протоколов
- Определение протокола (VLESS vs VMESS)
- Форматы конфигураций

✅ **Device ID:**
- Регистрация (200, 409)
- Отправка логов (200, 404)
- Повторная регистрация при 404

## Документация

- `docs/TESTING_SINGBOX_CONFIG.md` - Sing-box конфигурации
- `docs/TESTING_PROTOCOLS_AND_DEVICE_ID.md` - Протоколы и device_id

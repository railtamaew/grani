# Валидные тестовые конфигурации

## WireGuard

**Файл:** `wireguard_valid.conf`

✅ Содержит валидные WireGuard ключи (сгенерированы автоматически)
✅ Готова к использованию в тестах
⚠️  Endpoint = 127.0.0.1:51820 (для тестирования на localhost)

**Для реального подключения:**
1. Замените `Endpoint` на IP реального WireGuard сервера
2. Убедитесь, что сервер использует публичный ключ из `wireguard_server_keys.txt`

## Sing-box

### Минимальная конфигурация

**Файл:** `singbox_valid.json`

✅ Создает TUN интерфейс
✅ Использует 'direct' outbound (локальное подключение)
✅ Готова к использованию в тестах для проверки создания VPN интерфейса

**Ограничения:**
- Не создает реальное VPN подключение (только интерфейс)
- Подходит для тестирования парсинга конфигурации и создания интерфейса

### Конфигурация с VLESS

**Файл:** `singbox_vless_valid.json`

⚠️  Требует замены:
- `server`: IP или домен реального сервера
- `uuid`: Валидный UUID для VLESS
- `server_name`: Доменное имя для TLS

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

## Генерация новых ключей

Если нужно сгенерировать новые ключи:

```bash
./scripts/generate_valid_test_configs.sh
```

Это перезапишет существующие конфигурации новыми ключами.

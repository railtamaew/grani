# Тестирование sing-box конфигураций

Этот документ описывает систему тестирования sing-box конфигураций **перед сборкой APK**.

## Проблема

Ранее мы исправляли конфигурации, собирали APK, устанавливали на устройство, тестировали, находили ошибки, и цикл повторялся. Это неэффективно.

## Решение

Теперь мы тестируем конфигурации на сервере **до сборки APK**:

1. ✅ Генерируем конфигурации в Python (тот же формат, что в мобильном приложении)
2. ✅ Валидируем формат без запуска sing-box (быстро)
3. ✅ Валидируем через sing-box CLI или Docker (финальная проверка)
4. ✅ Только после успешных тестов переносим изменения в мобильное приложение

## Быстрый старт

### 1. Проверка формата (без sing-box)

```bash
# Быстрая проверка формата конфигураций
python3 scripts/test_singbox_config.py --validate-only
```

Это проверяет:
- ✅ Правильный формат DNS (объекты, а не строки)
- ✅ Отсутствие недопустимых полей (`dns_address`, `inet4_route`, `settings`)
- ✅ Правильный формат outbound (без `settings.vnext`)
- ✅ Правильный формат TLS/Reality

### 2. Валидация через sing-box (если установлен)

```bash
# Полная валидация через sing-box CLI
python3 scripts/test_singbox_config.py
```

### 3. Валидация через Docker (если sing-box не установлен)

```bash
# Валидация через Docker
python3 scripts/test_singbox_config.py --docker

# Или используйте отдельный скрипт
./scripts/test_singbox_docker.sh
```

### 4. Тестирование конкретного сценария

```bash
# Только VLESS + REALITY
python3 scripts/test_singbox_config.py --scenario reality

# Только VLESS + TLS
python3 scripts/test_singbox_config.py --scenario tls

# Только VMESS
python3 scripts/test_singbox_config.py --scenario vmess
```

### 5. Генерация конфигурации для проверки

```bash
# Генерация и вывод конфигурации
python3 scripts/test_singbox_config.py --generate

# Генерация и сохранение в файл
python3 scripts/test_singbox_config.py --generate --output /tmp/config.json
```

## Unit-тесты

Запуск unit-тестов для проверки формата:

```bash
cd backend
pytest tests/test_singbox_config_format.py -v
```

## Формат конфигурации

### ✅ ПРАВИЛЬНЫЙ формат (sing-box)

```json
{
  "outbounds": [{
    "type": "vless",
    "server": "45.12.132.94",
    "server_port": 443,
    "uuid": "test-uuid",
    "tls": {
      "enabled": true,
      "server_name": "www.google.com",
      "reality": {
        "public_key": "...",
        "short_id": "..."
      }
    }
  }]
}
```

### ❌ НЕПРАВИЛЬНЫЙ формат (старый Xray)

```json
{
  "outbounds": [{
    "type": "vless",
    "settings": {
      "vnext": [{
        "address": "45.12.132.94",
        "port": 443,
        "users": [{"uuid": "test-uuid"}]
      }]
    },
    "stream_settings": {
      "security": "reality"
    }
  }]
}
```

## Основные отличия sing-box от Xray

| Параметр | Xray | sing-box |
|----------|------|----------|
| Outbound формат | `settings.vnext` | `server`, `server_port` напрямую |
| TLS настройки | `stream_settings.security` | `tls.enabled` |
| REALITY | `stream_settings.reality_settings` | `tls.reality` |
| Transport | `stream_settings.network` | `transport.type` |
| DNS в TUN | `dns_address` в inbound | Только в секции `dns` |
| Маршруты | `inet4_route` | `auto_route` |

## Интеграция в процесс разработки

### Перед изменением конфигурации в мобильном приложении:

1. **Измените Python-скрипт** (`scripts/test_singbox_config.py`)
2. **Запустите тесты**: `python3 scripts/test_singbox_config.py`
3. **Убедитесь, что все тесты проходят**
4. **Только потом** переносите изменения в Dart/Kotlin

### Workflow:

```
1. Изменение в Python скрипте
   ↓
2. Тестирование (формат + sing-box)
   ↓
3. Перенос в мобильное приложение
   ↓
4. Сборка APK
   ↓
5. Тестирование на устройстве
```

## Примеры использования

### Проверка перед сборкой APK

```bash
# 1. Проверка формата (быстро)
python3 scripts/test_singbox_config.py --validate-only

# 2. Если формат корректен, валидация через sing-box
python3 scripts/test_singbox_config.py --docker

# 3. Если все тесты прошли, можно собирать APK
cd mobile-app
flutter build apk --debug
```

### Отладка конфигурации

```bash
# Генерируем конфигурацию и сохраняем
python3 scripts/test_singbox_config.py --generate --output /tmp/test_config.json

# Проверяем вручную
cat /tmp/test_config.json | jq .

# Валидируем через Docker
docker run --rm -i \
  -v /tmp/test_config.json:/config.json:ro \
  ghcr.io/sagernet/sing-box:latest \
  sing-box check -c /config.json
```

## Troubleshooting

### Ошибка: "sing-box не найден"

Используйте Docker:
```bash
python3 scripts/test_singbox_config.py --docker
```

### Ошибка: "Docker не найден"

Установите Docker или sing-box CLI:
- Docker: https://docs.docker.com/get-docker/
- sing-box: https://github.com/SagerNet/sing-box/releases

### Ошибка валидации

1. Проверьте формат через `--validate-only`
2. Посмотрите на ошибку sing-box
3. Сравните с правильным форматом в этом документе
4. Исправьте в Python-скрипте
5. Повторите тестирование

## Файлы

- `scripts/test_singbox_config.py` - Основной скрипт для тестирования
- `scripts/test_singbox_docker.sh` - Docker-версия
- `backend/tests/test_singbox_config_format.py` - Unit-тесты
- `docs/TESTING_SINGBOX_CONFIG.md` - Этот документ

## Следующие шаги

После успешного тестирования на сервере:

1. Перенесите изменения в `mobile-app/lib/protocols/xray/models/xray_config.dart`
2. Перенесите изменения в `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/XrayConfig.kt`
3. Обновите тесты в `mobile-app/test/protocols/xray/`
4. Соберите APK
5. Протестируйте на устройстве

# Быстрое тестирование sing-box конфигураций

## 🚀 Быстрый старт

### 1. Проверка формата (без sing-box, быстро)
```bash
python3 scripts/test_singbox_config.py --validate-only
```

### 2. Полная валидация (через Docker)
```bash
python3 scripts/test_singbox_config.py --docker
```

### 3. Генерация конфигурации для проверки
```bash
python3 scripts/test_singbox_config.py --generate
```

## 📋 Workflow перед сборкой APK

1. **Измените конфигурацию в Python-скрипте** (`scripts/test_singbox_config.py`)
2. **Проверьте формат**: `python3 scripts/test_singbox_config.py --validate-only`
3. **Валидируйте через sing-box**: `python3 scripts/test_singbox_config.py --docker`
4. **Только после успешных тестов** переносите в мобильное приложение
5. **Собирайте APK**

## ✅ Что проверяется

- ✅ Правильный формат DNS (объекты `{"address": "..."}`, не строки)
- ✅ Отсутствие недопустимых полей (`dns_address`, `inet4_route`, `settings`)
- ✅ Правильный формат outbound (без `settings.vnext`, с `server`/`server_port`)
- ✅ Правильный формат TLS/Reality (`tls.reality`, не `stream_settings.reality_settings`)

## 📖 Подробная документация

См. `docs/TESTING_SINGBOX_CONFIG.md`

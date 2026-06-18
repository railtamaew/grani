# 📦 Сборка APK v11-SINGBOX-FORMAT-FIXED

## 🚀 Скрипты сборки созданы

Созданы скрипты для сборки APK аналогично `granivpn-debug-dns-fixed.apk`:

### 1. `build_apk_v11.sh`
Базовый скрипт для сборки:
```bash
cd /opt/grani
./build_apk_v11.sh
```

### 2. `build_apk_v11_watch.sh`
Скрипт с выводом в реальном времени:
```bash
cd /opt/grani
./build_apk_v11_watch.sh
```

## 📋 Что делает скрипт

1. **Очистка проекта**: `flutter clean`
2. **Получение зависимостей**: `flutter pub get`
3. **Сборка APK**: `flutter build apk --debug`
4. **Копирование APK**: копирует в `/opt/grani/granivpn-debug-v11-singbox-format-fixed.apk`

## 📦 Результат

После успешной сборки APK будет находиться в:
```
/opt/grani/granivpn-debug-v11-singbox-format-fixed.apk
```

## 🔍 Проверка сборки

```bash
# Проверить наличие APK
ls -lh /opt/grani/granivpn-debug-v11-singbox-format-fixed.apk

# Проверить размер
du -h /opt/grani/granivpn-debug-v11-singbox-format-fixed.apk
```

## 📝 Версия кода

**Версия**: `2026-01-15-v11-SINGBOX-FORMAT-FIXED`

### Примененные изменения:

- ✅ Убран `settings.vnext` → используется `server`/`server_port`
- ✅ Убран `stream_settings` → используется `tls` и `transport`
- ✅ `reality_settings` → `tls.reality`
- ✅ DNS формат: объекты `{"address": "..."}`
- ✅ TUN inbound: без `dns_address`, `inet4_route`

## 🎯 Сравнение с предыдущей сборкой

**granivpn-debug-dns-fixed.apk**:
- Версия: v10 (DNS fix)
- Исправления: DNS формат

**granivpn-debug-v11-singbox-format-fixed.apk**:
- Версия: v11 (SINGBOX-FORMAT-FIXED)
- Исправления: полный формат sing-box конфигураций

## ✅ Статус

Скрипты созданы и готовы к использованию. Запустите сборку командой:
```bash
./build_apk_v11_watch.sh
```

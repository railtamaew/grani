# 📦 Инструкция по сборке APK

## 🚀 Команды для сборки

### Debug APK
```bash
cd /opt/grani/mobile-app
flutter clean
flutter pub get
flutter build apk --debug
```

### Release APK
```bash
cd /opt/grani/mobile-app
flutter clean
flutter pub get
flutter build apk --release
```

## 📁 Расположение собранных APK

После успешной сборки APK файлы находятся в:
```
mobile-app/build/app/outputs/flutter-apk/
```

## 🔍 Проверка сборки

```bash
# Проверить наличие APK файлов
ls -lh mobile-app/build/app/outputs/flutter-apk/*.apk

# Или найти все APK в проекте
find /opt/grani -name "*.apk" -type f
```

## ✅ Текущий статус

Все тесты созданы и готовы к выполнению перед сборкой APK.

Рекомендуется:
1. Запустить тесты: `python3 scripts/execute_tests.py`
2. Если все тесты пройдены → собрать APK
3. Протестировать APK на устройстве

## 📋 Версия кода

Текущая версия в `VpnService.kt`: `2026-01-15-v11-SINGBOX-FORMAT-FIXED`

Все изменения в формате sing-box конфигураций применены:
- ✅ Убран `settings.vnext` → используется `server`/`server_port`
- ✅ Убран `stream_settings` → используется `tls` и `transport`
- ✅ `reality_settings` → `tls.reality`
- ✅ DNS формат: объекты `{"address": "..."}`
- ✅ TUN inbound: без `dns_address`, `inet4_route`

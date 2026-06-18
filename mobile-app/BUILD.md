# 🚀 Быстрый старт сборки APK

## Автоматическая сборка с версионированием

Каждая сборка автоматически получает уникальную версию!

### Основная команда

```bash
cd /opt/grani/mobile-app
./scripts/build_apk.sh
```

**Что происходит:**
- ✅ Автоматически увеличивается build number (1.0.2+3 → 1.0.2+4)
- ✅ Обновляется `pubspec.yaml`
- ✅ Собирается release APK
- ✅ Сохраняется информация о сборке в `build_info.log`

### Другие варианты

```bash
# С очисткой проекта
./scripts/build_apk.sh --clean

# Увеличить patch версию (1.0.2 → 1.0.3)
./scripts/build_apk.sh --patch

# Установить конкретную версию
./scripts/build_apk.sh --version 1.1.0

# Release сборка (с очисткой)
./scripts/build_apk_release.sh
```

### Где найти APK

После сборки APK будет здесь:
```
build/app/outputs/flutter-apk/app-release.apk
```

### История сборок

Все сборки логируются в:
```
build_info.log
```

---

📖 Подробная документация: [README_BUILD.md](README_BUILD.md)

## Google Play и Google Sign-In (релиз)

- **Внутреннее/закрытое тестирование** в Play Console перед продом.
- **Google Sign-In на release**: в Firebase / GCP OAuth для клиента `com.granivpn.mobile` добавьте SHA-1 и SHA-256 **Play App Signing** и **upload key** (Gradle signing), иначе на устройствах из магазина будет `ApiException: 10`.
- Серверный чеклист биллинга: `backend/docs/GOOGLE_PLAY_PRODUCTION.md`.



# Сборка APK с автоматическим версионированием

## Автоматическая сборка

Скрипт `scripts/build_apk.sh` автоматически управляет версиями при каждой сборке.

### Основные команды

#### 1. Обычная сборка (автоинкремент build number)
```bash
./scripts/build_apk.sh
```
- Автоматически увеличивает build number (1.0.2+3 → 1.0.2+4)
- Версия приложения остается прежней

#### 2. Сборка с увеличением patch версии
```bash
./scripts/build_apk.sh --patch
```
- Увеличивает patch версию (1.0.2+3 → 1.0.3+4)
- Увеличивает build number

#### 3. Сборка с очисткой проекта
```bash
./scripts/build_apk.sh --clean
```
- Очищает проект перед сборкой
- Автоматически увеличивает build number

#### 4. Установка конкретной версии
```bash
./scripts/build_apk.sh --version 1.1.0
```
- Устанавливает версию 1.1.0
- Build number увеличивается автоматически

#### 5. Установка версии и build number
```bash
./scripts/build_apk.sh --version 1.1.0 --build 10
```
- Устанавливает версию 1.1.0 и build number 10

### Формат версии

Версия в `pubspec.yaml` имеет формат: `MAJOR.MINOR.PATCH+BUILD_NUMBER`

Примеры:
- `1.0.2+3` - версия 1.0.2, build 3
- `1.0.3+4` - версия 1.0.3, build 4
- `2.0.0+1` - версия 2.0.0, build 1

### Логирование

Информация о каждой сборке сохраняется в `build_info.log`:
- Версия
- Дата и время сборки
- Размер APK
- Путь к файлу

### Примеры использования

```bash
# Быстрая сборка с автоинкрементом
cd /opt/grani/mobile-app
./scripts/build_apk.sh

# Release сборка с очисткой
./scripts/build_apk_release.sh

# Новая минорная версия
./scripts/build_apk.sh --patch

# Установка конкретной версии для релиза
./scripts/build_apk.sh --version 1.1.0 --build 1
```

### Результат сборки

После успешной сборки APK будет находиться в:
```
build/app/outputs/flutter-apk/app-release.apk
```

Скрипт автоматически выведет:
- Путь к APK файлу
- Размер файла
- Версию сборки
- Время сборки

### Дополнительная документация

- [docs/APK_SIZE_AND_BUILD.md](docs/APK_SIZE_AND_BUILD.md) — анализ размера APK (`flutter build apk --analyze-size`), аудит ассетов.
- [docs/RETRY_AND_TIMEOUTS.md](docs/RETRY_AND_TIMEOUTS.md) — политики повторных запросов и таймауты.
- [docs/METRICS_AND_OBSERVABILITY.md](docs/METRICS_AND_OBSERVABILITY.md) — метрики старта (PerfLogger), этапы подключения VPN, Logger.



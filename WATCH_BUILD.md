# 📦 Отслеживание сборки APK в реальном времени

## 🚀 Способ 1: Прямой запуск с выводом

Выполните в терминале:

```bash
cd /opt/grani/mobile-app
flutter build apk --debug
```

## 🚀 Способ 2: Через скрипт с логами

Скрипт сохраняет вывод в файл, который можно отслеживать:

```bash
cd /opt/grani/mobile-app
./build_apk_with_log.sh
```

В другом терминале для просмотра в реальном времени:
```bash
tail -f /tmp/flutter_build_live.log
```

## 🚀 Способ 3: Через простой скрипт

```bash
cd /opt/grani/mobile-app
./build_apk_watch.sh
```

## 📋 Пошаговая сборка с выводом

Если нужно видеть каждый шаг:

```bash
cd /opt/grani/mobile-app

# 1. Очистка
echo "🧹 Очистка проекта..."
flutter clean

# 2. Зависимости
echo "📦 Получение зависимостей..."
flutter pub get

# 3. Сборка
echo "🔨 Сборка APK..."
flutter build apk --debug
```

## 🔍 Проверка результата

После завершения сборки:

```bash
# Проверить APK файлы
ls -lh mobile-app/build/app/outputs/flutter-apk/*.apk

# Или найти все APK
find /opt/grani -name "*.apk" -type f
```

## 📝 Примечания

- Сборка может занять несколько минут
- Вывод будет показывать прогресс компиляции
- В конце будет показан путь к собранному APK файлу

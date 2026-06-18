# Быстрое тестирование VPN протоколов

## ✅ Правильный подход (уже реализован)

### Unit-тесты (10 секунд, без APK)

```bash
cd /opt/grani/mobile-app/android
./gradlew test
```

**Что тестируется:**
- ✅ Парсинг WireGuard конфигураций
- ✅ Парсинг Sing-box конфигураций
- ✅ Логика VPN сервиса
- ✅ Обработка ошибок

**Преимущества:**
- ⚡ Запуск: 10 секунд
- 📦 Не нужен APK
- 🔄 Мгновенная обратная связь

---

## Быстрая установка в основном приложении

### Вариант 1: Полная сборка (5-10 минут)

```bash
cd /opt/grani/mobile-app/android
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

### Вариант 2: Только измененные модули (быстрее)

```bash
cd /opt/grani/mobile-app/android
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

### Вариант 3: Flutter hot reload (если возможно)

```bash
cd /opt/grani/mobile-app
flutter run
```

---

## ❌ НЕ делать

- ❌ Создавать новое тестовое приложение
- ❌ Собирать APK для каждого исправления
- ❌ Использовать Flutter для тестирования логики

---

## 🎯 Рекомендуемый workflow

1. **Исправляем код**
2. **Запускаем unit-тесты** (10 сек)
3. **Если тесты прошли → собираем APK** (5-10 мин)
4. **Устанавливаем и тестируем**

---

**Дата:** 20 января 2026

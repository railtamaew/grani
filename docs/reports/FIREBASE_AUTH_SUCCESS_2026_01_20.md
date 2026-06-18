# Авторизация в Firebase Test Lab - 20 января 2026

## ✅ Выполнено

### 1. Авторизация в Firebase

**Статус:** ✅ Успешно

**Детали:**
- **Аккаунт:** `rail.tamaew@gmail.com` (активный)
- **Проект:** `grani-479612`
- **API:** 
  - ✅ Cloud Testing API включен
  - ✅ Tool Results API включен

**Проверка:**
```bash
gcloud auth list --filter=status:ACTIVE
# rail.tamaew@gmail.com

gcloud config get-value project
# grani-479612
```

---

### 2. Исправление ошибки сборки APK

**Проблема:**
```
Conflicting configuration : 'armeabi-v7a,arm64-v8a,x86_64' in ndk abiFilters 
cannot be present when splits abi filters are set : armeabi-v7a,arm64-v8a
```

**Решение:**
- Отключены `splits` для debug сборки (нужен universal APK для Firebase Test Lab)
- Добавлен `x86_64` в список поддерживаемых ABI
- Включен `universalApk true` для debug сборки

**Изменения в `build.gradle`:**
```gradle
def isDebugBuild = gradle.startParameter.taskNames.any { it.toLowerCase().contains("debug") }
splits {
    abi {
        // Отключаем splits для debug сборки (для Firebase Test Lab нужен universal APK)
        enable !isBundleTask && !isDebugBuild
        reset()
        include 'arm64-v8a', 'armeabi-v7a', 'x86_64'
        universalApk true  // Для debug сборки нужен universal APK
    }
}
```

---

### 3. Сборка APK

**Результат:** ✅ Успешно

**APK файлы:**
- **Основной APK:** `build/app/outputs/apk/debug/app-debug.apk` (391 MB)
- **Тестовый APK:** `build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk` (84 KB)

**Команды сборки:**
```bash
# Основной APK
cd /opt/grani/mobile-app
flutter build apk --debug

# Тестовый APK
cd /opt/grani/mobile-app/android
./gradlew :app:assembleDebugAndroidTest
```

---

## 📊 Итоговый статус

| Компонент | Статус | Детали |
|-----------|--------|--------|
| Авторизация | ✅ | rail.tamaew@gmail.com |
| Проект | ✅ | grani-479612 |
| API | ✅ | Cloud Testing, Tool Results |
| Основной APK | ✅ | 391 MB |
| Тестовый APK | ✅ | 84 KB |
| Готовность к тестам | ✅ | Все готово |

---

## 🚀 Следующие шаги

### Запуск тестов в Firebase Test Lab

**1. Проверка настройки:**
```bash
cd /opt/grani/mobile-app/android
./scripts/check_firebase_setup.sh
```

**2. Запуск тестов:**
```bash
cd /opt/grani/mobile-app/android
./scripts/run_firebase_tests.sh \
    --singbox-config test_configs/singbox_minimal.json \
    --device-model Pixel2.arm \
    --device-version 30
```

**3. Просмотр результатов:**
- Веб-интерфейс: https://console.firebase.google.com/project/grani-479612/testlab/histories
- Или через CLI: `gcloud firebase test android results list`

---

## 📝 Что тестируется

### 1. Автоматическое выдача VPN разрешения
- UI Automator автоматически принимает системный диалог VPN
- Работает в Firebase Test Lab

### 2. Запуск VPN сервиса
- Проверяется запуск с конфигурацией sing-box (XRay) и WireGuard
- Проверяется статус `isVpnRunning()`

### 3. Реальное VPN подключение (НОВОЕ)
- ✅ Проверяется статистика трафика (`rx_bytes`, `tx_bytes`)
- ✅ Генерируется тестовый трафик через VPN
- ✅ Проверяется, что трафик увеличился (VPN маршрутизирует трафик)

**Подробности:** См. `/opt/grani/docs/reports/FIREBASE_TEST_COVERAGE_2026_01_20.md`

---

## ✅ Готово к использованию

Все компоненты настроены и готовы к запуску тестов в Firebase Test Lab.

**Дата:** 20 января 2026  
**Версия:** 1.0

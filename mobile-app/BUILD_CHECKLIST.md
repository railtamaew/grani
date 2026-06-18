# ✅ Чек-лист сборки APK

## Перед каждой сборкой

- [ ] **1. Изменили версию CODE_VERSION в коде**
  - Файл: `android/app/src/main/kotlin/com/granivpn/mobile/VpnService.kt`
  - Формат: `"2026-01-15-v6-FIXED"` → `"2026-01-15-v7-FIXED"`
  - Проверка: `grep "CODE_VERSION" android/app/src/main/kotlin/com/granivpn/mobile/VpnService.kt`

- [ ] **2. Выполнили полную очистку**
  - `./build_apk_clean.sh` (автоматически)
  - Или вручную:
    ```bash
    flutter clean
    cd android && ./gradlew clean --no-daemon && ./gradlew --stop && cd ..
    rm -rf android/.gradle android/app/build android/build .gradle build
    ```

- [ ] **3. Остановили все daemon процессы**
  - `pkill -f gradle`
  - `pkill -f kotlin`
  - `./gradlew --stop`

- [ ] **4. Собрали APK с правильными флагами**
  - DEBUG: `flutter build apk --debug --no-tree-shake-icons`
  - RELEASE: `flutter build apk --release --split-per-abi --target-platform android-arm64 --no-tree-shake-icons`

- [ ] **5. Проверили, что версия попала в APK**
  ```bash
  unzip -q -o app-debug.apk -d /tmp/check
  strings /tmp/check/classes.dex | grep "CODE_VERSION"
  ```

- [ ] **6. Проверили логи после установки**
  ```bash
  adb logcat | grep -i "GraniVpnService\|CODE_VERSION\|2026-01-15"
  ```

## Использование скрипта

### DEBUG версия (по умолчанию):
```bash
cd /opt/grani/mobile-app
./build_apk_clean.sh
```

### RELEASE версия:
```bash
cd /opt/grani/mobile-app
./build_apk_clean.sh release
```

## Признаки проблем

### ❌ APK не меняется после изменений кода:
1. Остановитесь
2. Проверьте версию в исходниках
3. Выполните полную очистку
4. Пересоберите с флагами принудительной пересборки
5. Проверьте результат

### ❌ Версия не найдена в APK:
- Код не скомпилировался
- Используется старый APK
- Проблема с путями сборки

### ❌ Версия не появляется в логах:
- APK не установлен правильно
- Код не выполняется
- Логи не выводятся

## Важные файлы

- `android/app/src/main/kotlin/com/granivpn/mobile/VpnService.kt` - основной код
- `android/build.gradle` - настройки buildDir (не менять без необходимости)
- `android/app/build.gradle` - настройки компиляции Kotlin
- `android/gradle.properties` - настройки кэширования

## История проблем

**14 января 2026:** Добавлен кастомный `buildDir` в `android/build.gradle` во время реорганизации проекта. Это привело к проблемам с путями сборки.

**15 января 2026:** Проблема с кэшированием - старые классы не пересобирались. Решение: полная очистка + принудительная пересборка.

**Решение:** Создан скрипт `build_apk_clean.sh` для автоматизации процесса.

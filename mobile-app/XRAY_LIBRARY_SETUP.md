# Настройка библиотек XRay-core

## Текущий статус

Структура для библиотек XRay-core создана, но реальные `.so` файлы еще не добавлены. 
Для работы XRay необходимо добавить библиотеки `libxray.so` для всех архитектур Android.

## Архитектуры

- `arm64-v8a` - 64-bit ARM (современные устройства)
- `armeabi-v7a` - 32-bit ARM (старые устройства)  
- `x86` - 32-bit x86 (эмуляторы)
- `x86_64` - 64-bit x86 (эмуляторы)

## Варианты получения библиотек

### Вариант 1: Сборка через libXray (рекомендуется)

```bash
# 1. Установить Go 1.25+ и gomobile
export PATH=$PATH:/usr/local/go/bin
go install golang.org/x/mobile/cmd/gomobile@latest
gomobile init

# 2. Клонировать libXray
git clone https://github.com/XTLS/libXray.git
cd libXray

# 3. Собрать для Android
python3 build/main.py android

# 4. Скопировать .so файлы
# Результаты сборки будут в build/output/ или подобной директории
# Скопируйте libxray.so для каждой архитектуры в:
# mobile-app/android/app/src/main/jniLibs/arm64-v8a/libxray.so
# mobile-app/android/app/src/main/jniLibs/armeabi-v7a/libxray.so
# mobile-app/android/app/src/main/jniLibs/x86/libxray.so
# mobile-app/android/app/src/main/jniLibs/x86_64/libxray.so
```

### Вариант 2: Использовать готовые решения

#### libv2ray (совместим с XRay)
```bash
# Проверить релизы: https://github.com/2dust/libv2ray/releases
# Скачать AAR или .so файлы
# Извлечь и скопировать в jniLibs/
```

### Вариант 3: Ручная сборка XRay-core

Требуется:
- Go 1.25+
- Android NDK
- Настройка кросс-компиляции

```bash
git clone https://github.com/XTLS/Xray-core.git
cd Xray-core
# Настроить сборку для Android с экспортом JNI функций
# Это сложный процесс, рекомендуется использовать libXray
```

## Проверка библиотек

После добавления библиотек проверьте:

```bash
cd /opt/grani/mobile-app/android/app/src/main/jniLibs
file arm64-v8a/libxray.so  # Должен быть: ELF 64-bit LSB shared object, ARM aarch64
file armeabi-v7a/libxray.so # Должен быть: ELF 32-bit LSB shared object, ARM
```

## Важно

1. **JNI функции**: Библиотека должна экспортировать функции, объявленные в `XrayCoreJni.kt`:
   - `Java_com_granivpn_mobile_XrayCoreJni_startXray`
   - `Java_com_granivpn_mobile_XrayCoreJni_stopXray`
   - `Java_com_granivpn_mobile_XrayCoreJni_isXrayRunning`
   - И другие

2. **Имена функций**: Если используете готовую библиотеку (например, libv2ray), может потребоваться адаптация JNI обертки под её API.

3. **Тестирование**: После добавления библиотек протестируйте на реальном устройстве.

## Текущее состояние

- ✅ Структура директорий создана
- ✅ JNI обертка готова (`XrayCoreJni.kt`)
- ✅ Парсер конфигураций готов (`XrayConfigParser.kt`)
- ✅ Интеграция в VpnService готова
- ⏳ Ожидается добавление реальных `.so` файлов

## Следующие шаги

1. Добавить реальные `libxray.so` файлы в `jniLibs/`
2. Протестировать загрузку библиотеки
3. Протестировать подключение через XRay протоколы
4. При необходимости адаптировать JNI обертку под API библиотеки



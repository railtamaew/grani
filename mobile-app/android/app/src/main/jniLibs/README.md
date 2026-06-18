# XRay-core Native Libraries

Эта директория содержит нативные библиотеки XRay-core для различных архитектур Android.

## Структура

- `arm64-v8a/libxray.so` - для 64-bit ARM устройств (современные Android устройства)
- `armeabi-v7a/libxray.so` - для 32-bit ARM устройств (старые устройства)
- `x86/libxray.so` - для 32-bit x86 эмуляторов
- `x86_64/libxray.so` - для 64-bit x86 эмуляторов

## Получение библиотек

### Вариант 1: Скачать готовые релизы

1. Перейти на https://github.com/XTLS/Xray-core/releases
2. Скачать последнюю версию для Android
3. Извлечь `.so` файлы в соответствующие директории

### Вариант 2: Собрать через gomobile

```bash
# Установить gomobile
go install golang.org/x/mobile/cmd/gomobile@latest
gomobile init

# Клонировать XRay-core
git clone https://github.com/XTLS/Xray-core.git
cd Xray-core

# Собрать для Android
gomobile bind -target=android -o xray.aar ./main
```

### Вариант 3: Использовать libv2ray-android

Альтернативный вариант - использовать готовую библиотеку `libv2ray-android`:
- GitHub: https://github.com/2dust/libv2ray
- Добавить как AAR зависимость в `build.gradle`

## Примечание

Библиотеки должны быть добавлены вручную перед сборкой приложения. 
После добавления библиотек, JNI обертка (`XrayCoreJni.kt`) сможет их загрузить.



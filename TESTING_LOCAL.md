# Локальное тестирование до активации upload key

## Обзор

До активации нового upload key в Google Play (16 января 2026, 10:10 МСК) нельзя загружать AAB/APK в Google Play Console. Для тестирования XRay протоколов используйте локальную установку release APK на устройства.

## Процесс тестирования

### 1. Сборка release APK

Используйте скрипт `build_release_apk_local.sh` для сборки подписанного release APK:

```bash
cd /opt/grani
./build_release_apk_local.sh
```

**Что делает скрипт:**
- Проверяет наличие keystore и конфигурации подписи
- Получает версию из `android/local.properties`
- Собирает release APK с правильной подписью
- Сохраняет APK с версионированием в `release_apks/app-release-v{version}+{code}.apk`
- Проверяет подпись APK

**Результат:**
- APK файл будет сохранен в `/opt/grani/release_apks/`
- Имя файла включает версию: `app-release-v1.0.2+8.apk`
- APK подписан release keystore (тот же, что будет использоваться для Google Play)

### 2. Установка APK на устройство

Используйте скрипт `install_release_apk.sh` для установки на подключенное устройство:

```bash
cd /opt/grani
./install_release_apk.sh
```

**Требования:**
- Android устройство подключено через USB
- Включена отладка по USB на устройстве
- ADB доступен в системе

**Что делает скрипт:**
- Проверяет подключенные устройства
- Находит последний собранный APK
- Деинсталлирует предыдущую версию (если установлена)
- Устанавливает новый APK
- Настраивает логирование для XRay протоколов
- Запускает приложение

**Package name:** `com.granivpn.mobile` (release версия, не debug)

### 3. Просмотр логов XRay протоколов

Логи автоматически сохраняются в `/opt/grani/logs/xray_test_{timestamp}.log`

**Просмотр в реальном времени:**
```bash
tail -f /opt/grani/logs/xray_test_*.log
```

**Остановка логирования:**
```bash
pkill -f 'adb.*logcat.*com.granivpn.mobile'
```

**Что логируется:**
- Сообщения от `GraniVpnService` (Kotlin)
- Сообщения от `SingBoxWrapper` (Kotlin)
- Сообщения от `VpnService` (Flutter)
- Сообщения от XRay протоколов

## Что тестировать до 16 января

### XRay протоколы

1. **VLESS протокол:**
   - Подключение через VLESS
   - Проверка парсинга конфигурации
   - Проверка работы VPN интерфейса

2. **VMESS протокол:**
   - Подключение через VMESS
   - Проверка шифрования
   - Проверка стабильности соединения

3. **REALITY протокол:**
   - Подключение через REALITY
   - Проверка TLS handshake
   - Проверка обхода блокировок

### Проверка работы SingBoxWrapper

- Проверка создания VPN интерфейса
- Проверка обработки пакетов
- Проверка статистики трафика
- Проверка остановки VPN

### Общие проверки

- Стабильность подключения
- Переподключение при обрыве
- Работа с разными серверами
- Производительность и использование ресурсов

## Структура файлов

```
/opt/grani/
├── build_release_apk_local.sh    # Скрипт сборки APK
├── install_release_apk.sh        # Скрипт установки APK
├── release_apks/                  # Собранные APK файлы
│   └── app-release-v1.0.2+8.apk
└── logs/                          # Логи тестирования
    └── xray_test_20260114_120000.log
```

## Устранение проблем

### APK не собирается

1. Проверьте наличие keystore:
   ```bash
   ls -lh /opt/grani/mobile-app/android/granivpn-release-key.jks
   ```

2. Проверьте конфигурацию подписи:
   ```bash
   cat /opt/grani/mobile-app/android/key.properties
   ```

3. Проверьте логи сборки:
   ```bash
   tail -100 /tmp/release_apk_local_build_*.log
   ```

### Устройство не найдено

1. Проверьте подключение устройства:
   ```bash
   adb devices
   ```

2. Убедитесь, что включена отладка по USB на устройстве

3. Перезапустите ADB сервер:
   ```bash
   adb kill-server
   adb start-server
   ```

### APK не устанавливается

1. Проверьте, что устройство поддерживает установку из неизвестных источников

2. Попробуйте установить вручную:
   ```bash
   adb install -r /opt/grani/release_apks/app-release-v*.apk
   ```

3. Проверьте, что package name правильный (`com.granivpn.mobile`)

### Логи не сохраняются

1. Проверьте права доступа к директории логов:
   ```bash
   ls -ld /opt/grani/logs
   ```

2. Проверьте, что logcat процесс запущен:
   ```bash
   ps aux | grep logcat
   ```

## После активации upload key (16 января)

После активации нового upload key:

1. Пересоберите AAB:
   ```bash
   cd /opt/grani/mobile-app
   flutter build appbundle --release
   ```

2. Загрузите AAB в Google Play Console

3. Ошибка подписи должна исчезнуть

## Дополнительные ресурсы

- [Документация Flutter - Android App Bundle](https://docs.flutter.dev/deployment/android)
- [Google Play App Signing](https://support.google.com/googleplay/android-developer/answer/9842756)
- [ADB команды](https://developer.android.com/studio/command-line/adb)

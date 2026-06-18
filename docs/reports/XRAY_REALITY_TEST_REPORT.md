# Отчет о тестировании Xray Reality протокола

## Выполненные задачи

### 1. ✅ Очистка кеша
- **Flutter кеш**: Очищен через `flutter clean`
- **Android build кеш**: Очищен через `./gradlew clean`
- **Результат**: Все кеши успешно очищены

### 2. ✅ Сборка APK
- **Проблема**: Ошибка R8 при минификации из-за отсутствующих классов Google Play Core
- **Решение**: Добавлены правила ProGuard для игнорирования отсутствующих классов:
  ```proguard
  -dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
  -dontwarn com.google.android.play.core.splitinstall.**
  -dontwarn com.google.android.play.core.tasks.**
  ```
- **Результат**: APK успешно собран
  - Файл: `/opt/grani/granivpn-release.apk`
  - Размер: 150MB
  - Путь: `build/app/outputs/flutter-apk/app-release.apk`

### 3. ✅ Анализ реализации Xray Reality

#### Backend реализация:
- **Файл**: `backend/services/xray_manager.py`
- **Метод**: `create_reality_client()` - создает REALITY клиента
- **Метод**: `_generate_reality_config()` - генерирует конфигурацию REALITY
- **Поддержка**: Протокол `xray_reality` поддерживается в API

#### Mobile App реализация:
- **Файл**: `mobile-app/lib/services/vpn_service.dart`
- **Протокол**: `VpnProtocol.xrayReality` поддерживается
- **Метод**: `_connectXray()` - обрабатывает подключение через Xray протоколы

#### API Endpoint:
- **URL**: `POST /api/vpn/connect`
- **Параметры**: 
  - `server_id`: ID сервера
  - `device_id`: ID устройства
  - `protocol`: `xray_reality`

## Проблемы при тестировании

### Проблема с аутентификацией
При попытке тестирования через API возникает ошибка:
```
{"error":{"code":"UNAUTHORIZED","message":"Неверный токен"}}
```

**Возможные причины**:
1. Несоответствие SECRET_KEY между генерацией токена и проверкой
2. Истекший срок действия токена
3. Проблемы с форматом токена в заголовках

## Рекомендации для тестирования

### Способ 1: Через мобильное приложение (рекомендуется)
1. Установите собранный APK на устройство:
   ```bash
   adb install /opt/grani/granivpn-release.apk
   ```
2. Запустите приложение
3. Выберите сервер с поддержкой Xray Reality
4. Выберите протокол **Xray Reality**
5. Подключитесь

### Способ 2: Через VPN Tester скрипт
```bash
cd /opt/grani/backend
python3 scripts/vpn_tester.py
```
Затем:
1. Выберите `1` - Получить токен
2. Выберите `2` - Подключиться к VPN
3. Введите ID сервера (например, `1`)
4. Введите протокол: `xray_reality`

### Способ 3: Прямое тестирование через API (после исправления аутентификации)
```bash
# Получить токен
TOKEN=$(python3 -c "...")

# Подключиться через Xray Reality
curl -X POST "http://localhost:8000/api/vpn/connect" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "server_id": 1,
    "device_id": "test-device",
    "protocol": "xray_reality"
  }'
```

## Проверка конфигурации сервера

Перед тестированием убедитесь, что:
1. **Сервер поддерживает Xray Reality**:
   - Проверьте поле `reality_enabled` в базе данных
   - Проверьте наличие `reality_config` с необходимыми параметрами:
     - `serverName`
     - `dest`
     - `publicKey`
     - `privateKey`
     - `shortId`

2. **Xray установлен и запущен на сервере**:
   ```bash
   ssh root@<server_ip> "systemctl status xray"
   ```

3. **Порт открыт**:
   ```bash
   ssh root@<server_ip> "ss -tlnp | grep <xray_port>"
   ```

## Следующие шаги

1. **Исправить проблему с аутентификацией** для тестирования через API
2. **Протестировать подключение через мобильное приложение** (APK готов)
3. **Проверить логи бэкенда** при попытке подключения
4. **Проверить конфигурацию Xray на сервере** для Reality протокола

## Файлы изменены

1. `/opt/grani/mobile-app/android/app/proguard-rules.pro` - добавлены правила ProGuard
2. `/opt/grani/granivpn-release.apk` - собранный APK файл

## Дата тестирования
2025-12-30



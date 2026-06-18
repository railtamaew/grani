# Статус системы логирования клиентов

## Результаты проверки

**Дата проверки:** 2026-01-15  
**Пользователь:** rail.tamaew@gmail.com (ID=1)

---

## ✅ Что работает

1. **Router зарегистрирован:**
   - ✅ `client_logs` успешно импортирован
   - ✅ Router зарегистрирован в `main.py`
   - ✅ Endpoint: `/api/vpn/logs/send`
   - ✅ Prefix: `/api/vpn/logs`

2. **Таблица в базе данных:**
   - ✅ Таблица `client_logs` существует
   - ✅ Все необходимые колонки присутствуют (17 колонок)
   - ✅ Индексы созданы

3. **Пользователь и устройства:**
   - ✅ Пользователь найден: ID=1, email=rail.tamaew@gmail.com
   - ✅ У пользователя есть 3 устройства:
     - `cursor-vpn-tester-root` (ID=1)
     - `UKQ1.230924.001` (ID=2)
     - `test-device-api` (ID=5)

---

## ❌ Проблема

**В базе данных НЕТ НИ ОДНОГО ЛОГА:**
- Всего логов: 0
- Логи для пользователя rail.tamaew@gmail.com: 0
- Логи для всех пользователей: 0

---

## Возможные причины

### 1. ConnectionLogger не отправляет логи (404 ошибка)
**Проблема:** В логах была ошибка 404 при отправке логов

**Проверка:**
- Endpoint существует: `/api/vpn/logs/send` ✅
- Router зарегистрирован ✅
- Путь правильный: `baseUrl` + `/vpn/logs/send` = `/api/vpn/logs/send` ✅

**Возможная причина:**
- Router может быть не зарегистрирован при запуске сервера (если был ImportError)
- Нужно проверить логи сервера при запуске

### 2. Устройство не найдено (404)
**Проблема:** Endpoint возвращает 404, если устройство не найдено

**Проверка:**
- У пользователя есть устройства ✅
- Но `device_id` в запросе должен совпадать с `device_id` в таблице `devices`

**Возможная причина:**
- Flutter отправляет `device_id` из `DeviceInfoPlugin`, который может отличаться от зарегистрированного
- Нужно проверить, какой `device_id` отправляется из приложения

### 3. Токен авторизации не передается
**Проблема:** Endpoint требует авторизацию

**Проверка:**
- ConnectionLogger использует `Authorization: Bearer $token` ✅
- Но токен может быть не установлен или истек

**Возможная причина:**
- `setCredentials()` не вызывается или вызывается с пустым токеном
- Токен истекает до отправки логов

### 4. Логи накапливаются, но не отправляются
**Проблема:** Логи накапливаются в `_pendingLogs`, но `_flushLogs()` не вызывается

**Проверка:**
- Таймер запускается каждые 30 секунд ✅
- Но может быть проблема с credentials

**Возможная причина:**
- `_cachedToken` или `_cachedDeviceId` не установлены
- `_flushLogs()` возвращается раньше из-за проверки credentials

---

## Рекомендации для исправления

### 1. Проверить логи сервера при запуске
```bash
# Проверить, что router зарегистрирован
grep -i "client_logs\|VPN Client Logs" /var/log/.../app.log
```

### 2. Добавить логирование в ConnectionLogger
В `connection_logger.dart` добавить больше debug логов:
```dart
debugPrint('ConnectionLogger._flushLogs: token=${_cachedToken != null}, deviceId=${_cachedDeviceId != null}');
debugPrint('ConnectionLogger._flushLogs: pendingLogs=${_pendingLogs.length}');
debugPrint('ConnectionLogger._flushLogs: URL=${AppConfig.apiBaseUrl}/vpn/logs/send');
```

### 3. Проверить device_id
Убедиться, что `device_id` в запросе совпадает с зарегистрированным:
- Flutter: `DeviceInfoPlugin().androidInfo.id`
- База данных: `devices.device_id`

### 4. Тестировать endpoint вручную
```bash
# Получить токен
TOKEN=$(python3 backend/get_admin_token.py rail.tamaew@gmail.com | grep "Bearer" | awk '{print $2}')

# Отправить тестовый лог
curl -X POST http://159.223.199.122:8000/api/vpn/logs/send \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "device_id": "UKQ1.230924.001",
    "logs": [{
      "event_type": "connection_start",
      "protocol": "xray_vless"
    }]
  }'
```

### 5. Проверить, вызывается ли setCredentials
В `vpn_service.dart` проверить, что `logger.setCredentials()` вызывается:
```dart
// Должно быть в методе connect()
logger.setCredentials(token, _deviceId!);
```

---

## Следующие шаги

1. ✅ Проверить логи сервера при запуске
2. ✅ Добавить больше debug логов в ConnectionLogger
3. ✅ Проверить, что device_id совпадает
4. ✅ Протестировать endpoint вручную
5. ✅ Проверить, что setCredentials вызывается

---

## Вывод

**Система логирования настроена правильно, но логи не поступают.**

Наиболее вероятные причины:
1. Router не зарегистрирован при запуске (нужно проверить логи сервера)
2. device_id не совпадает с зарегистрированным
3. Токен не установлен или истек
4. Логи накапливаются, но не отправляются из-за отсутствия credentials

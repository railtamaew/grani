# Использование Xray API для тестирования протоколов

## Обзор

API для работы с Xray протоколами (VLESS, VMESS, REALITY) доступен без сборки мобильного приложения. Можно тестировать через curl, Postman или любой HTTP клиент.

## Базовый URL

```
http://localhost:8000/api/vpn/xray
```

## Аутентификация

Все запросы требуют Bearer токен в заголовке `Authorization`.

### Получение токена

1. **Отправка кода на email:**
```bash
curl -X POST "http://localhost:8000/api/auth/send-code" \
  -H "Content-Type: application/json" \
  -d '{"email": "your-email@example.com"}'
```

2. **Проверка кода и получение токена:**
```bash
curl -X POST "http://localhost:8000/api/auth/verify-code" \
  -H "Content-Type: application/json" \
  -d '{
    "email": "your-email@example.com",
    "code": "123456"
  }'
```

Ответ содержит `access_token` - используйте его в заголовке:
```
Authorization: Bearer YOUR_ACCESS_TOKEN
```

## Регистрация устройства

Перед созданием клиента нужно зарегистрировать устройство:

```bash
curl -X POST "http://localhost:8000/api/vpn/device/register" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_ACCESS_TOKEN" \
  -d '{
    "device_id": "test-device-123",
    "name": "Test Device",
    "platform": "android"
  }'
```

## Создание Xray клиента

### VLESS протокол

```bash
curl -X POST "http://localhost:8000/api/vpn/xray/create-client" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_ACCESS_TOKEN" \
  -d '{
    "server_id": 1,
    "device_id": "test-device-123",
    "protocol": "xray_vless"
  }'
```

**Ответ:**
```json
{
  "success": true,
  "client_id": "vless_1_1",
  "config": "vless://uuid@45.12.132.94:443?...",
  "json_config": {...},
  "protocol": "vless",
  "server_name": "HU-BUD-01",
  "ip_address": "45.12.132.94",
  "message": "Xray клиент успешно создан"
}
```

### VMESS протокол

```bash
curl -X POST "http://localhost:8000/api/vpn/xray/create-client" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_ACCESS_TOKEN" \
  -d '{
    "server_id": 1,
    "device_id": "test-device-123",
    "protocol": "xray_vmess"
  }'
```

### REALITY протокол

```bash
curl -X POST "http://localhost:8000/api/vpn/xray/create-client" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_ACCESS_TOKEN" \
  -d '{
    "server_id": 1,
    "device_id": "test-device-123",
    "protocol": "xray_reality"
  }'
```

## Получение статистики

### Статистика сервера

```bash
curl -X GET "http://localhost:8000/api/vpn/xray/stats?server_id=1" \
  -H "Authorization: Bearer YOUR_ACCESS_TOKEN"
```

**Ответ:**
```json
{
  "total_uplink": 0,
  "total_downlink": 0,
  "active_clients": 0,
  "total_clients": 81,
  "timestamp": "2026-01-14T10:12:49.252428",
  "protocol": "xray",
  "server_id": 1,
  "server_name": "HU-BUD-01"
}
```

**Параметры:**
- `server_id` (опционально) - ID сервера. Если не указан, используется первый активный сервер.

### Статистика клиента

```bash
curl -X GET "http://localhost:8000/api/vpn/xray/client-stats/vless_1_1" \
  -H "Authorization: Bearer YOUR_ACCESS_TOKEN"
```

**Ответ:**
```json
{
  "client_id": "vless_1_1",
  "stats": {
    "uplink": 0,
    "downlink": 0,
    "client_id": "vless_1_1",
    "client_email": "1_1@granivpn.com",
    "timestamp": "2026-01-14T10:12:49.252428"
  },
  "timestamp": "2026-01-14T10:12:49.252428"
}
```

**Примечание:** Статистика скорости трафика получается через Xray Stats API (порт 10085). Если Stats API недоступен, возвращаются нулевые значения.

## Проверка здоровья сервера

```bash
curl -X GET "http://localhost:8000/api/vpn/xray/health?server_id=1" \
  -H "Authorization: Bearer YOUR_ACCESS_TOKEN"
```

**Ответ:**
```json
{
  "status": "healthy",
  "message": "Xray работает"
}
```

или

```json
{
  "status": "error",
  "message": "Xray не запущен: ..."
}
```

## Удаление клиента

```bash
curl -X DELETE "http://localhost:8000/api/vpn/xray/client/vless_1_1" \
  -H "Authorization: Bearer YOUR_ACCESS_TOKEN"
```

## Получение конфигурации клиента

```bash
curl -X GET "http://localhost:8000/api/vpn/xray/config/vless_1_1" \
  -H "Authorization: Bearer YOUR_ACCESS_TOKEN"
```

## Пример полного теста

```bash
#!/bin/bash

# 1. Получить токен (замените email и code)
TOKEN=$(curl -s -X POST "http://localhost:8000/api/auth/verify-code" \
  -H "Content-Type: application/json" \
  -d '{"email": "your-email@example.com", "code": "123456"}' \
  | jq -r '.access_token')

echo "Token: $TOKEN"

# 2. Зарегистрировать устройство
curl -X POST "http://localhost:8000/api/vpn/device/register" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "device_id": "test-device-123",
    "name": "Test Device",
    "platform": "android"
  }' | jq

# 3. Создать VLESS клиента
curl -X POST "http://localhost:8000/api/vpn/xray/create-client" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "server_id": 1,
    "device_id": "test-device-123",
    "protocol": "xray_vless"
  }' | jq

# 4. Получить статистику
curl -X GET "http://localhost:8000/api/vpn/xray/stats?server_id=1" \
  -H "Authorization: Bearer $TOKEN" | jq
```

## Измерение скорости трафика

Статистика скорости получается через Xray Stats API. Для работы необходимо:

1. **Настроить Xray Stats API на сервере:**
   - Добавить DOKODEMO-DOOR inbound на порту 10085
   - Включить Stats в конфигурации Xray

2. **Проверить доступность Stats API:**
```bash
# Через SSH на сервере
curl http://127.0.0.1:10085/stats?reset=false
```

3. **Использовать API для получения статистики:**
   - Статистика сервера: `GET /api/vpn/xray/stats?server_id=1`
   - Статистика клиента: `GET /api/vpn/xray/client-stats/{client_id}`

**Примечание:** Если Stats API недоступен, методы возвращают нулевые значения, но количество клиентов берется из конфигурации Xray.

## Ошибки

### Устройство не найдено
```json
{
  "detail": "Устройство не найдено. Пожалуйста, зарегистрируйте устройство через /vpn/device/register"
}
```

### Сервер не найден
```json
{
  "detail": "Сервер не найден или неактивен"
}
```

### Протокол не поддерживается
```json
{
  "detail": "Сервер не поддерживает протокол xray_vless. Доступные протоколы: ..."
}
```

## Поддерживаемые протоколы

- `xray_vless` - VLESS протокол
- `xray_vmess` - VMESS протокол  
- `xray_reality` - REALITY протокол (требует настройки на сервере)

## Дополнительная информация

- Все протоколы работают через SSH подключение к VPN серверам
- Конфигурация Xray читается и записывается на сервер автоматически
- Клиенты создаются с уникальными UUID
- Email клиента имеет формат: `{user_id}_{device_id}@granivpn.com`
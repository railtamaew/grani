# Отправка логов на сервер

Минимальное приложение настроено для автоматической отправки логов на сервер.

## 🎯 Как это работает

1. **Логирование в приложении:**
   - Все действия логируются через `SimpleLogger`
   - Логи накапливаются в памяти
   - Отправка на сервер каждые 30 секунд или при накоплении 10+ логов

2. **Отправка на сервер:**
   - Endpoint: `POST /api/vpn/logs/test`
   - Без авторизации (публичный endpoint)
   - Сохранение в файл: `/opt/grani/logs/test_apps/vpn-minimal_YYYYMMDD.log`

3. **Просмотр логов:**
   - На сервере: `/opt/grani/logs/test_apps/vpn-minimal_*.log`
   - Формат: `timestamp | level | tag | message | extra`

## 📊 Что логируется

- ✅ Запуск приложения
- ✅ Начало подключения VPN
- ✅ Успешное подключение
- ✅ Ошибки подключения
- ✅ Отключение VPN
- ✅ Все действия пользователя

## 🔍 Просмотр логов на сервере

### В реальном времени:

```bash
tail -f /opt/grani/logs/test_apps/vpn-minimal_$(date +%Y%m%d).log
```

### Поиск по уровню:

```bash
# Только ошибки
grep "ERROR" /opt/grani/logs/test_apps/vpn-minimal_*.log

# Только INFO
grep "INFO" /opt/grani/logs/test_apps/vpn-minimal_*.log
```

### Поиск по тегу:

```bash
# Только VPN логи
grep "VPN" /opt/grani/logs/test_apps/vpn-minimal_*.log
```

## 📝 Формат логов

```
2026-01-20T11:45:30.123Z | INFO | VPN | Начало подключения VPN
2026-01-20T11:45:30.456Z | DEBUG | VPN | Конфигурация подготовлена | extra: {"config_length": 234}
2026-01-20T11:45:31.789Z | INFO | VPN | VPN подключен успешно
2026-01-20T11:46:00.123Z | INFO | VPN | Начало отключения VPN
2026-01-20T11:46:00.456Z | INFO | VPN | VPN отключен успешно
```

## ⚙️ Настройка

### Включить/выключить логирование:

```dart
final logger = SimpleLogger();
logger.setEnabled(false); // Выключить
logger.setEnabled(true);  // Включить
```

### Принудительная отправка:

```dart
final logger = SimpleLogger();
await logger.flush(); // Отправить все накопленные логи немедленно
```

## 🔧 API Endpoint

**URL:** `POST http://159.223.199.122:8000/api/vpn/logs/test`

**Request:**
```json
{
  "app": "vpn-minimal",
  "logs": [
    {
      "timestamp": "2026-01-20T11:45:30.123Z",
      "level": "INFO",
      "tag": "VPN",
      "message": "Начало подключения VPN",
      "extra": null
    }
  ]
}
```

**Response:**
```json
{
  "ok": true,
  "message": "Получено 1 логов",
  "logs_count": 1,
  "saved_to": "/opt/grani/logs/test_apps/vpn-minimal_20260120.log"
}
```

## ✅ Преимущества

1. **Не нужен ADB** - логи приходят автоматически
2. **Работает на любом устройстве** - не нужен USB
3. **История логов** - все сохраняется на сервере
4. **Удобный анализ** - можно фильтровать и искать
5. **Автоматическая отправка** - не нужно ничего делать вручную

---

**Дата создания:** 20 января 2026  
**Версия:** 1.0

# Реализация получения логов с VPN серверов

**Дата:** 2025-01-20  
**Статус:** ✅ Реализовано и покрыто тестами

---

## 📋 Обзор

Добавлена функциональность для получения логов с VPN серверов (XRay и WireGuard) через SSH. Это позволяет администраторам диагностировать проблемы подключения и мониторить работу VPN серверов.

---

## ✅ Что было реализовано

### 1. Методы получения логов в RemoteVPNManager

**Файл:** `backend/services/remote_vpn_manager.py`

#### Метод `get_xray_logs()`
- Получает логи XRay с удаленного сервера
- Поддерживает 3 типа логов:
  - `access` - логи доступа из `/var/log/xray/access.log`
  - `error` - логи ошибок из `/var/log/xray/error.log`
  - `journalctl` - логи через systemd journal
- Параметры:
  - `server` - объект сервера
  - `log_type` - тип лога (по умолчанию "access")
  - `lines` - количество строк (по умолчанию 100)
  - `follow` - следить за логами в реальном времени (не поддерживается через SSH)

#### Метод `get_wireguard_logs()`
- Получает логи WireGuard с удаленного сервера
- Использует `journalctl` для получения логов systemd
- Параметры:
  - `server` - объект сервера
  - `lines` - количество строк (по умолчанию 100)
  - `interface` - имя интерфейса WireGuard (по умолчанию "wg0")

### 2. API Endpoint для получения логов

**Файл:** `backend/api/vpn.py`

**Endpoint:** `GET /api/vpn/server/{server_id}/logs`

**Параметры запроса:**
- `log_type` - тип лога для XRay: "access", "error", "journalctl" (по умолчанию "access")
- `protocol` - протокол: "xray" или "wireguard" (по умолчанию "xray")
- `lines` - количество строк (максимум 1000, по умолчанию 100)

**Требования:**
- Только для администраторов (требуется токен админа)

**Пример запроса:**
```bash
curl -X GET "https://api.example.com/api/vpn/server/1/logs?protocol=xray&log_type=access&lines=200" \
  -H "Authorization: Bearer <admin_token>"
```

**Пример ответа:**
```json
{
  "server_id": 1,
  "server_name": "Hungary VPN Server",
  "protocol": "xray",
  "log_type": "access",
  "lines_count": 50,
  "logs": [
    "2024-01-20 10:00:00 INFO: Connection established",
    "2024-01-20 10:01:00 INFO: Client connected"
  ]
}
```

### 3. Тесты

**Файлы:**
- `backend/tests/test_remote_vpn_manager_logs.py` - тесты для методов RemoteVPNManager
- `backend/tests/test_vpn_api_logs.py` - тесты для API endpoint

**Покрытие:**
- ✅ Успешное получение логов XRay (access, error, journalctl)
- ✅ Успешное получение логов WireGuard
- ✅ Обработка ошибок SSH
- ✅ Обработка недоступности SSH
- ✅ Обработка исключений
- ✅ Обработка пустого вывода
- ✅ Разные количества строк
- ✅ Кастомные интерфейсы WireGuard
- ✅ API endpoint с авторизацией
- ✅ API endpoint с ошибками

**Результаты тестов:**
```
14 passed, 2 warnings in 1.66s
```

---

## 🔧 Использование

### Через Python код:

```python
from services.remote_vpn_manager import RemoteVPNManager
from models.server import Server

# Получаем сервер из БД
server = db.query(Server).filter(Server.id == 1).first()

# Создаем менеджер
remote_manager = RemoteVPNManager()

# Получаем access логи XRay
xray_logs = remote_manager.get_xray_logs(server, log_type="access", lines=100)
if xray_logs['success']:
    for log_line in xray_logs['logs']:
        print(log_line)

# Получаем логи WireGuard
wg_logs = remote_manager.get_wireguard_logs(server, lines=50)
if wg_logs['success']:
    for log_line in wg_logs['logs']:
        print(log_line)
```

### Через API:

```bash
# Получить access логи XRay
curl -X GET "http://localhost:8000/api/vpn/server/1/logs?protocol=xray&log_type=access&lines=100" \
  -H "Authorization: Bearer <admin_token>"

# Получить error логи XRay
curl -X GET "http://localhost:8000/api/vpn/server/1/logs?protocol=xray&log_type=error&lines=50" \
  -H "Authorization: Bearer <admin_token>"

# Получить логи WireGuard
curl -X GET "http://localhost:8000/api/vpn/server/1/logs?protocol=wireguard&lines=200" \
  -H "Authorization: Bearer <admin_token>"
```

---

## 📊 Формат возвращаемых данных

### Успешный ответ:
```python
{
    'success': True,
    'log_type': 'access',  # или 'error', 'journalctl', 'wireguard'
    'server_id': 1,
    'lines_count': 50,
    'logs': [
        '2024-01-20 10:00:00 INFO: Connection established',
        '2024-01-20 10:01:00 INFO: Client connected'
    ],
    'raw_output': '...'  # Полный вывод команды
}
```

### Ошибка:
```python
{
    'success': False,
    'error': 'Connection refused',
    'logs': []
}
```

---

## ⚠️ Важные замечания

1. **SSH доступ:** Для получения логов требуется SSH доступ к VPN серверу. Убедитесь, что:
   - Настроены SSH ключи или пароль
   - Сервер доступен по SSH
   - Пользователь имеет права на чтение логов

2. **Безопасность:**
   - API endpoint доступен только администраторам
   - Логи могут содержать чувствительную информацию
   - Рекомендуется ограничить доступ к endpoint

3. **Производительность:**
   - Получение большого количества строк может быть медленным
   - Максимальное количество строк ограничено 1000
   - Рекомендуется использовать разумные значения `lines`

4. **Логирование:**
   - Логи XRay должны быть настроены в конфигурации XRay
   - Логи WireGuard доступны через systemd journal
   - Если логи не найдены, метод вернет пустой список

---

## 🚀 Следующие шаги

1. **Автоматический сбор логов:**
   - Настроить периодический сбор логов
   - Сохранять логи на backend сервере
   - Настроить ротацию логов

2. **Централизованное хранение:**
   - Настроить rsyslog или аналогичную систему
   - Создать централизованное хранилище логов
   - Добавить веб-интерфейс для просмотра

3. **Анализ логов:**
   - Добавить парсинг логов
   - Создать статистику подключений
   - Настроить алерты на ошибки

---

## 📝 Измененные файлы

1. `backend/services/remote_vpn_manager.py` - добавлены методы `get_xray_logs()` и `get_wireguard_logs()`
2. `backend/api/vpn.py` - добавлен endpoint `GET /api/vpn/server/{server_id}/logs`
3. `backend/tests/test_remote_vpn_manager_logs.py` - тесты для методов RemoteVPNManager
4. `backend/tests/test_vpn_api_logs.py` - тесты для API endpoint

---

## ✅ Проверка работоспособности

Все тесты проходят успешно:
```bash
cd /opt/grani/backend
python3 -m pytest tests/test_remote_vpn_manager_logs.py -v
# 14 passed, 2 warnings in 1.66s
```

---

**Статус:** ✅ Готово к использованию

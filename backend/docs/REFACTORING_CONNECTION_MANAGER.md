# План рефакторинга ConnectionManager

## Проблема

`ConnectionManager` имеет слишком много ответственности (нарушение Single Responsibility Principle):
- Регистрация устройств
- Подключение устройств (через разные протоколы)
- Отключение устройств
- Получение статуса устройств
- Статистика подключений
- Очистка неактивных подключений
- Системная статистика

Это усложняет:
- Тестирование
- Добавление новых протоколов
- Поддержку кода
- Понимание логики

## План разделения

### 1. DeviceManager
**Ответственность:** Управление устройствами
- `register_device()` - регистрация устройства
- `get_user_devices()` - получение списка устройств пользователя
- `get_device_by_id()` - получение устройства по ID
- `update_device()` - обновление информации об устройстве

### 2. ConnectionOrchestrator
**Ответственность:** Оркестрация подключений
- `connect_device()` - подключение устройства (выбор протокола, координация)
- `disconnect_device()` - отключение устройства
- `_connect_wireguard()` - подключение через WireGuard
- `_connect_xray()` - подключение через Xray
- `_connect_openvpn()` - подключение через OpenVPN (если нужно)

### 3. ConnectionMonitor
**Ответственность:** Мониторинг подключений
- `get_device_status()` - статус устройства
- `get_connection_stats()` - статистика подключений пользователя
- `get_system_stats()` - системная статистика
- `cleanup_inactive_connections()` - очистка неактивных подключений

### 4. ProtocolManagerFactory
**Ответственность:** Создание менеджеров протоколов
- `get_manager_for_protocol()` - получение менеджера для протокола
- `get_wireguard_manager()` - получение WireGuard менеджера
- `get_xray_manager()` - получение Xray менеджера

## Интерфейс VPN менеджеров

Создать протокол/интерфейс для единообразной работы с VPN менеджерами:

```python
from typing import Protocol, Dict, Any
from models.user import Device
from models.server import Server

class VPNManagerProtocol(Protocol):
    """Протокол для VPN менеджеров"""
    
    def connect_device(self, device: Device, server: Server) -> Dict[str, Any]:
        """Подключение устройства"""
        ...
    
    def disconnect_device(self, device: Device, server: Server) -> bool:
        """Отключение устройства"""
        ...
    
    def get_device_status(self, device: Device, server: Server) -> Dict[str, Any]:
        """Получение статуса устройства"""
        ...
```

## Этапы выполнения

### Этап 1: Создание интерфейса (БЕЗОПАСНО)
1. Создать `services/protocols/vpn_manager_protocol.py` с протоколом
2. Обновить существующие менеджеры для соответствия протоколу (не меняя логику)
3. Добавить тесты для проверки соответствия протоколу

### Этап 2: Создание DeviceManager (ОСТОРОЖНО)
1. Создать `services/device_manager.py`
2. Перенести методы регистрации и получения устройств
3. Обновить `VPNOperationsService` для использования `DeviceManager`
4. Тестирование

### Этап 3: Создание ConnectionOrchestrator (ОСТОРОЖНО)
1. Создать `services/connection_orchestrator.py`
2. Перенести методы подключения/отключения
3. Использовать протокол для работы с менеджерами
4. Обновить `VPNOperationsService`
5. Тестирование

### Этап 4: Создание ConnectionMonitor (ОСТОРОЖНО)
1. Создать `services/connection_monitor.py`
2. Перенести методы мониторинга и статистики
3. Обновить зависимости
4. Тестирование

### Этап 5: Удаление ConnectionManager (РИСКОВАННО)
1. Убедиться, что все методы перенесены
2. Обновить все зависимости
3. Удалить `ConnectionManager`
4. Полное тестирование

## Риски

- **Высокий риск:** Изменение логики подключения может сломать VPN
- **Средний риск:** Изменение зависимостей может сломать другие сервисы
- **Низкий риск:** Создание интерфейса не меняет существующую логику

## Рекомендации

1. Начать с Этапа 1 (интерфейс) - это безопасно
2. Добавить тесты для каждого этапа
3. Выполнять этапы последовательно
4. Тестировать после каждого этапа
5. Не удалять `ConnectionManager` до полного завершения всех этапов

## Текущий статус

- ✅ План создан
- ✅ Этап 1: Протокол VPN менеджеров создан
- ✅ Этап 2: DeviceManager создан и интегрирован
  - Создан `services/device_manager.py`
  - Методы `register_device()` и `get_user_devices()` перенесены
  - `VPNOperationsService` обновлен для использования `DeviceManager`
  - Добавлена зависимость в `core/dependencies.py`
  - Сохранена обратная совместимость с `ConnectionManager`
- ✅ Этап 3: ConnectionOrchestrator создан и интегрирован
  - Создан `services/connection_orchestrator.py`
  - Методы `connect_device()`, `disconnect_device()`, `_connect_wireguard()`, `_connect_xray()` перенесены
  - `VPNOperationsService` обновлен для использования `ConnectionOrchestrator`
  - Добавлена зависимость `get_connection_orchestrator()` в `core/dependencies.py`
  - Сохранена обратная совместимость с `ConnectionManager`
- ✅ Этап 4: ConnectionMonitor создан и интегрирован
  - Создан `services/connection_monitor.py`
  - Методы `get_device_status()`, `get_connection_stats()`, `get_system_stats()`, `cleanup_inactive_connections()` перенесены
  - `VPNOperationsService` обновлен для использования `ConnectionMonitor`
  - Добавлена зависимость `get_connection_monitor()` в `core/dependencies.py`
  - Сохранена обратная совместимость с `ConnectionManager`
- ⏳ Этап 5: Удаление ConnectionManager (ожидает полного тестирования)

## Итоговый статус

✅ **Рефакторинг практически завершен!**

Все основные методы ConnectionManager успешно перенесены в специализированные классы:
- DeviceManager - управление устройствами
- ConnectionOrchestrator - координация подключений
- ConnectionMonitor - мониторинг и статистика

**Обратная совместимость:** 100% - ConnectionManager остается доступным для старых компонентов

**API endpoints обновлены:** Используют новые менеджеры с fallback на ConnectionManager

**Следующий шаг:** Полное тестирование перед удалением ConnectionManager

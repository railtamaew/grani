# Анализ структуры backend

**Дата:** 2026-01-21

## Текущая ситуация

### Используемая структура (активная)
- `backend/services/` - используется в API endpoints
- `backend/models/` - используется в API endpoints
- `backend/repositories/` - используется в сервисах

### Дубликаты (не используются)
- `backend/application/services/` - дубликаты сервисов
- `backend/domain/models/` - дубликаты моделей
- `backend/infrastructure/repositories/` - дубликаты репозиториев

## Анализ импортов

### API endpoints используют:
- `from services.auth_service import AuthService`
- `from services.vpn_operations_service import VPNOperationsService`
- `from models.user import User, Device`
- `from models.server import Server`

### core/dependencies.py имеет fallback:
```python
try:
    from application.services.device_manager import DeviceManager
    ...
except ImportError:
    # Fallback на старую структуру
    from services.device_manager import DeviceManager
    ...
```

Это означает, что новая структура не используется, и fallback всегда срабатывает.

## Рекомендация

**Вариант 1: Удалить дубликаты (рекомендуется)**
- Удалить `backend/application/`
- Удалить `backend/domain/`
- Удалить `backend/infrastructure/`
- Оставить только `services/`, `models/`, `repositories/`

**Вариант 2: Мигрировать на новую структуру**
- Обновить все импорты в API на новую структуру
- Удалить старую структуру
- Обновить `core/dependencies.py`

## Решение

Выбираем **Вариант 1** - удалить дубликаты, так как:
1. Старая структура активно используется
2. Новая структура не используется нигде
3. Меньше рисков при удалении неиспользуемого кода

# Архитектура проекта GRANI VPN

## Общая структура

Проект следует принципам разделения ответственности и слоистой архитектуры.

## Слои приложения

### 1. API Layer (`backend/api/`)
**Ответственность:** Обработка HTTP запросов, валидация входных данных, маршрутизация

**Принципы:**
- Тонкие контроллеры - минимум бизнес-логики
- Делегирование бизнес-логики сервисам
- Использование Pydantic для валидации
- Стандартизированные ответы

**Файлы:**
- `api/vpn.py` - VPN операции (использует `VPNOperationsService`)
- `api/xray.py` - Xray операции (использует `VPNOperationsService`)
- `api/auth.py` - Аутентификация (использует `AuthService`)
- `api/admin.py` - Админ-панель (использует различные сервисы)

### 2. Service Layer (`backend/services/`)
**Ответственность:** Бизнес-логика приложения

**Принципы:**
- Один сервис = одна область ответственности
- Сервисы не зависят от API слоя
- Использование репозиториев для доступа к данным

**Основные сервисы:**
- `VPNOperationsService` - операции с VPN (регистрация устройств, подключение, отключение)
- `AuthService` - аутентификация и авторизация
- `ConnectionManager` - управление VPN подключениями (WireGuard, Xray, OpenVPN)
- `WireGuardManager` - управление WireGuard
- `XrayManager` - управление Xray
- `ServerSelector` - выбор оптимального сервера
- `ServerLoadCalculator` - расчет нагрузки серверов

### 3. Repository Layer (`backend/repositories/`)
**Ответственность:** Абстракция доступа к данным

**Принципы:**
- Инкапсуляция SQL запросов
- Переиспользуемые методы для работы с моделями
- Базовый класс `BaseRepository` с CRUD операциями

**Репозитории:**
- `DeviceRepository` - работа с устройствами
- `ServerRepository` - работа с серверами
- `UserRepository` - работа с пользователями

### 4. Model Layer (`backend/models/`)
**Ответственность:** Определение структуры данных

**Принципы:**
- SQLAlchemy ORM модели
- Минимум бизнес-логики в моделях
- Использование relationships для связей

### 5. Core Layer (`backend/core/`)
**Ответственность:** Общая инфраструктура и утилиты

**Компоненты:**
- `database.py` - настройка БД и сессий
- `config.py` - конфигурация приложения
- `dependencies.py` - FastAPI зависимости
- `exception_handlers.py` - централизованная обработка ошибок
- `error_types.py` - типы ошибок
- `constants.py` - константы приложения
- `rbac.py` - управление правами доступа (RBAC)
- `cache.py` - кэширование
- `country_mapping.py` - маппинг стран

## Потоки данных

### Типичный запрос:
1. **API Endpoint** получает HTTP запрос
2. **Валидация** через Pydantic модели
3. **Аутентификация** через `AuthService`
4. **Бизнес-логика** в сервисах
5. **Доступ к данным** через репозитории
6. **Ответ** через API endpoint

### Пример: Подключение к VPN
```
Client → api/vpn.py::connect_vpn()
  → VPNOperationsService::get_or_create_connection() (режим без device_id)
    ИЛИ VPNOperationsService::connect_device() (режим с device_id)
    → DeviceRepository::get_by_device_id()
    → ServerRepository::get_active_by_id()
    → XrayManager / WireGuardManager
```

## Зависимости

```
API Layer
  ↓
Service Layer
  ↓
Repository Layer
  ↓
Model Layer
  ↓
Database
```

## Принципы проектирования

1. **Separation of Concerns** - разделение ответственности между слоями
2. **Dependency Injection** - зависимости передаются через конструкторы
3. **Single Responsibility** - каждый класс отвечает за одну задачу
4. **DRY** - избегание дублирования кода
5. **SOLID** - следование принципам SOLID

## Обработка ошибок

Все ошибки обрабатываются централизованно через `core/exception_handlers.py`:
- `HTTPException` - стандартные HTTP ошибки
- `RequestValidationError` - ошибки валидации Pydantic
- `SQLAlchemyError` - ошибки базы данных
- `Exception` - все остальные исключения

Формат ошибок стандартизирован через `core/error_types.py`.

## Кэширование

Используется in-memory кэш (`core/cache.py`) для:
- Списка серверов
- Статуса WireGuard
- Результатов выбора серверов

## Безопасность

- JWT токены для аутентификации
- RBAC для управления правами доступа
- Валидация всех входных данных
- Проверка прав доступа в критичных endpoints

## Тестирование

- Unit тесты для сервисов (`tests/`)
- Использование SQLite in-memory для изоляции тестов
- Фикстуры для создания тестовых данных

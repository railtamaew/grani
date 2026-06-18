# Phase 3: Реорганизация структуры проекта

**Дата:** 2026-01-14  
**Статус:** В процессе выполнения

## Цель

Реорганизовать проект по принципам Clean Architecture:
- **Domain** - бизнес-логика и модели
- **Application** - use cases и сервисы
- **Infrastructure** - репозитории, внешние зависимости

## Новая структура

```
backend/
├── domain/              # Доменный слой (бизнес-логика)
│   ├── models/         # Модели данных (SQLAlchemy)
│   ├── entities/       # Бизнес-сущности (опционально)
│   └── interfaces/     # Интерфейсы/протоколы
│
├── application/        # Слой приложения (use cases)
│   ├── services/       # Бизнес-сервисы
│   ├── use_cases/     # Use cases (опционально)
│   └── dto/           # Data Transfer Objects
│
├── infrastructure/     # Инфраструктурный слой
│   ├── repositories/  # Репозитории (доступ к данным)
│   ├── external/      # Внешние сервисы (email, VPN managers)
│   ├── database/      # Настройки БД
│   └── cache/         # Кэширование
│
├── api/               # API слой (FastAPI endpoints)
├── core/              # Общие утилиты (config, constants, etc.)
├── middleware/        # Middleware
└── main.py           # Точка входа
```

## Этапы выполнения

### Этап 1: Создание новой структуры папок
- [x] Создать domain/models
- [ ] Создать application/services
- [ ] Создать infrastructure/repositories
- [ ] Создать infrastructure/external

### Этап 2: Перенос моделей
- [ ] Перенести models/ → domain/models/
- [ ] Обновить импорты в domain/models

### Этап 3: Перенос сервисов
- [ ] Перенести бизнес-сервисы в application/services/
- [ ] Перенести инфраструктурные сервисы в infrastructure/external/

### Этап 4: Перенос репозиториев
- [ ] Перенести repositories/ → infrastructure/repositories/

### Этап 5: Dependency Injection
- [ ] Создать DI контейнер
- [ ] Настроить регистрацию зависимостей
- [ ] Обновить core/dependencies.py

### Этап 6: Обновление импортов
- [ ] Обновить все импорты в проекте
- [ ] Обновить main.py
- [ ] Обновить API endpoints

### Этап 7: Тестирование
- [ ] Запустить все тесты
- [ ] Проверить работу API
- [ ] Проверить работу сервисов

## Классификация сервисов

### Application Services (бизнес-логика):
- auth_service.py
- code_service.py
- vpn_operations_service.py
- device_manager.py
- connection_orchestrator.py
- connection_monitor.py
- health_service.py
- server_selector.py
- server_load_calculator.py
- protocol_analyzer.py
- provider_monitor.py
- trial_service.py
- telemetry_service.py
- app_config_service.py
- admin_auth_service.py

### Infrastructure Services (внешние зависимости):
- wireguard_manager.py
- xray_manager.py
- openvpn_manager.py
- cloak_manager.py
- ssh_manager.py
- remote_vpn_manager.py
- email_service.py
- celery_app.py

## Dependency Injection

Используем простой DI контейнер на основе словаря:
- Регистрация зависимостей при старте приложения
- Резолв зависимостей через FastAPI Depends
- Поддержка singleton и factory паттернов

## Риски

1. **Высокий риск** - изменение всех импортов может сломать приложение
2. **Требуется полное тестирование** после каждого этапа
3. **Возможны проблемы с циклическими импортами**

## Стратегия миграции

1. Создать новую структуру параллельно со старой
2. Постепенно переносить код
3. Обновлять импорты по одному модулю
4. Тестировать после каждого изменения
5. Удалить старую структуру только после полной миграции

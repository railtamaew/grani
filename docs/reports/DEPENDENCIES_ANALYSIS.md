# Анализ зависимостей проекта

**Дата:** 2026-01-04

## Admin Panel (package.json)

### Используемые зависимости:
- ✅ `react`, `react-dom` - основной фреймворк
- ✅ `@mui/material`, `@mui/icons-material` - UI компоненты
- ✅ `@reduxjs/toolkit`, `react-redux` - управление состоянием
- ✅ `@tanstack/react-query` - кэширование
- ✅ `axios` - HTTP клиент
- ✅ `react-router-dom` - маршрутизация
- ✅ `recharts` - графики (используется в DashboardPage)
- ✅ `typescript` - типизация
- ✅ `react-scripts` - сборка

### Возможно неиспользуемые зависимости:
- ⚠️ `react-hook-form` - не найдено использований в коде
- ⚠️ `yup` - не найдено использований в коде
- ⚠️ `date-fns` - не найдено использований в коде
- ⚠️ `web-vitals` - не найдено использований (обычно используется в index.tsx)

### Тестовые зависимости (devDependencies):
- ✅ `@testing-library/*` - для тестирования
- ✅ `@types/*` - типы TypeScript
- ✅ `eslint` - линтер

## Mobile App (pubspec.yaml)

### Используемые зависимости:
- ✅ `flutter` - основной фреймворк
- ✅ `provider` - управление состоянием
- ✅ `dio`, `http` - сетевые запросы
- ✅ `shared_preferences`, `flutter_secure_storage` - локальное хранение
- ✅ `flutter_svg`, `cached_network_image` - работа с изображениями
- ✅ `google_sign_in` - авторизация
- ✅ `webview_flutter` - платежи
- ✅ `get_it` - dependency injection
- ✅ `crypto` - криптография

### Возможно неиспользуемые зависимости:
- ⚠️ `sqflite` - не найдено использований (используется только shared_preferences)
- ⚠️ `hive`, `hive_flutter` - не найдено использований (используется только shared_preferences)
- ⚠️ `basic_utils` - не найдено использований

### Закомментированные зависимости:
- ✅ `firebase_messaging`, `firebase_core` - временно отключено (правильно)
- ✅ `pointycastle` - временно отключено (правильно)

## Backend (requirements.txt)

### Используемые зависимости:
- ✅ `fastapi`, `uvicorn` - веб-фреймворк
- ✅ `sqlalchemy`, `psycopg2-binary` - база данных
- ✅ `redis` - используется в admin_auth_service для rate limiting
- ✅ `python-jose`, `PyJWT` - JWT токены
- ✅ `passlib` - хеширование паролей
- ✅ `pydantic` - валидация данных
- ✅ `boto3` - AWS/Yandex Cloud
- ✅ `celery` - фоновые задачи (используется в server_monitoring_tasks)
- ✅ `cryptography` - криптография
- ✅ `pywireguard` - WireGuard протокол

### Возможно неиспользуемые зависимости:
- ⚠️ `flower` - мониторинг Celery (не найдено использований в коде, но может использоваться отдельно)
- ⚠️ `pytz` - не найдено прямых использований (используется datetime.utcnow() вместо pytz, но Celery может использовать)

## Рекомендации

### Admin Panel:
1. Проверить использование `react-hook-form`, `yup`, `date-fns`
2. Если не используются - удалить из package.json
3. `web-vitals` обычно используется в index.tsx для метрик

### Mobile App:
1. Проверить использование `sqflite`, `hive`, `basic_utils`
2. Если не используются - удалить из pubspec.yaml
3. Это может уменьшить размер APK

### Backend:
1. `flower` - инструмент для мониторинга Celery (может использоваться отдельно)
2. `pytz` - используется Celery для timezone (celery_app.py: timezone='UTC')
3. Оставить, так как Celery использует pytz для работы с timezone

## Потенциальная экономия

- Удаление неиспользуемых зависимостей может:
  - Уменьшить размер node_modules (admin-panel) - ~50-100MB
  - Уменьшить размер APK (mobile-app) - ~5-10MB
  - Ускорить установку зависимостей

## Итоговые рекомендации

### Высокий приоритет:
1. **Mobile App**: Удалить `sqflite`, `hive`, `hive_flutter`, `basic_utils` если не используются
2. **Admin Panel**: Проверить и удалить `react-hook-form`, `yup`, `date-fns` если не используются

### Низкий приоритет:
1. **Backend**: `flower` и `pytz` оставить (используются Celery)
2. **Admin Panel**: `web-vitals` можно оставить для метрик производительности

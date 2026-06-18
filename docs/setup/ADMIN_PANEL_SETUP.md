# Инструкция по развертыванию и тестированию админ-панели GRANI

## Выполненные задачи

✅ Все компоненты админ-панели реализованы:
- Backend модели, сервисы, API эндпоинты
- Frontend тема, компоненты, страницы
- RBAC система с ролями
- Rate limiting для логина
- Audit log
- Телеметрия и инциденты

## Шаги для запуска

### 1. Применение миграций БД

```bash
cd /opt/grani/backend
psql -U granivpn_user -d granivpn -f migrations/add_admin_features.sql
```

Или через Python:

```python
from core.database import engine
from models import user, protocol, telemetry, audit_log, admin_login_log
from models.user import User
from services.auth_service import AuthService
from sqlalchemy.orm import Session
from core.database import SessionLocal

# Создание таблиц
Base.metadata.create_all(bind=engine)

# Создание первого Owner пользователя
db = SessionLocal()
admin_email = "admin@granilink.com"
admin_password = "your-secure-password"
password_hash = AuthService.hash_password(admin_password)

owner = User(
    email=admin_email,
    password_hash=password_hash,
    role="owner",
    is_active=True,
    is_verified=True
)
db.add(owner)
db.commit()
```

### 2. Настройка переменных окружения

Обновите `.env` файл:

```bash
ADMIN_MAX_LOGIN_ATTEMPTS=10
ADMIN_LOCKOUT_DURATION_MINUTES=15
REDIS_URL=redis://localhost:6379/0
```

### 3. Запуск Backend

```bash
cd /opt/grani/backend
uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

### 4. Запуск Frontend (локально)

```bash
cd /opt/grani/admin-panel
npm install
npm start
```

Админка будет доступна на `http://localhost:3000`

### 5. Настройка Nginx для продакшена

Добавьте в конфигурацию nginx для `granilink.com`:

```nginx
location /admin {
    proxy_pass https://spectacular-begonia-477baa.netlify.app;
    proxy_set_header Host spectacular-begonia-477baa.netlify.app;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_ssl_verify off;
}
```

Или используйте готовый файл: `server-config/nginx/admin-path.conf`

## Тестирование

### Проверка API эндпоинтов

1. **Логин:**
```bash
curl -X POST http://localhost:8000/api/admin/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email": "admin@granilink.com", "password": "your-password"}'
```

2. **Получение текущего админа:**
```bash
curl -X GET http://localhost:8000/api/admin/auth/me \
  -H "Authorization: Bearer YOUR_TOKEN"
```

3. **Список пользователей:**
```bash
curl -X GET "http://localhost:8000/api/admin/users?skip=0&limit=10" \
  -H "Authorization: Bearer YOUR_TOKEN"
```

### Проверка через браузер

1. Откройте `http://localhost:3000` (локально) или `https://granilink.com/admin` (продакшен)
2. Войдите с учетными данными Owner/Admin пользователя
3. Проверьте:
   - ✅ Отображение логотипа GRANI
   - ✅ Цветовая схема (светлая тема с цветами GRANI)
   - ✅ Навигация по меню
   - ✅ Доступ к страницам согласно ролям
   - ✅ Rate limiting (10 неудачных попыток → блокировка на 15 минут)

### Тестирование ролей

- **Owner**: Доступ ко всем страницам, включая Settings и Audit Log
- **Admin**: Доступ к Users, Protocols, Servers, Incidents (без Settings)
- **Support**: Доступ к чтению + работа с инцидентами
- **Read-only**: Только просмотр всех страниц

### Тестирование Rate Limiting

1. Попробуйте войти с неверным паролем 10 раз
2. После 10-й попытки должна появиться блокировка
3. Повторная попытка должна показать сообщение о блокировке

## Структура API

### Аутентификация
- `POST /api/admin/auth/login` - Вход с rate limiting
- `POST /api/admin/auth/logout` - Выход
- `GET /api/admin/auth/me` - Текущий админ

### Пользователи
- `GET /api/admin/users` - Список с фильтрами
- `GET /api/admin/users/:id` - Детальная карточка
- `PATCH /api/admin/users/:id` - Обновление
- `POST /api/admin/users/:id/subscription` - Создание подписки
- `POST /api/admin/users/:id/trial` - Установка trial
- `DELETE /api/admin/users/:id` - Удаление (soft)

### Протоколы
- `GET /api/admin/protocols` - Список
- `POST /api/admin/protocols` - Создание
- `PATCH /api/admin/protocols/:id` - Обновление
- `POST /api/admin/protocols/:id/enable` - Включение
- `POST /api/admin/protocols/:id/disable` - Выключение

### Инциденты
- `GET /api/admin/incidents` - Список с фильтрами
- `GET /api/admin/incidents/:id` - Детальная карточка
- `PATCH /api/admin/incidents/:id` - Обновление статуса

### Audit Log
- `GET /api/admin/audit-log` - История действий админов

## Важные замечания

1. **Первый Owner пользователь** должен быть создан вручную через SQL или скрипт
2. **Redis** необходим для работы rate limiting (опционально, но рекомендуется)
3. **Миграции БД** должны быть применены перед запуском
4. **CORS** настройки должны включать домен админ-панели

## Следующие шаги для расширения функциональности

Страницы созданы в базовом виде. Можно расширить:
- Полная реализация таблиц с DataGrid
- Модальные окна для создания/редактирования
- Графики и статистика на Dashboard
- Детальные формы для всех сущностей

Все API эндпоинты готовы и работают!




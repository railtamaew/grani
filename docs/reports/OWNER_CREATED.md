# ✅ Owner пользователь создан

## Информация о пользователе

- **Email:** rail.tamaew@gmail.com
- **Роль:** Owner
- **Пароль:** ChangeThisPassword123! ⚠️ **ИЗМЕНИТЕ ПОСЛЕ ПЕРВОГО ВХОДА!**

## Что было сделано

1. ✅ Применены миграции БД (`add_admin_features.sql`)
   - Добавлены колонки в таблицы users, devices, subscriptions, servers
   - Созданы таблицы: protocols, telemetry_events, audit_logs, admin_login_logs

2. ✅ Обновлен пользователь rail.tamaew@gmail.com
   - Установлена роль: Owner
   - Пользователь активирован и верифицирован
   - Установлен пароль по умолчанию

## Следующие шаги

1. **Войти в админ-панель:**
   - URL: https://granilink.com/admin или http://localhost:3000 (если запущен локально)
   - Email: rail.tamaew@gmail.com
   - Пароль: ChangeThisPassword123!

2. **Сразу изменить пароль** после первого входа

3. **Создать других администраторов** при необходимости:
   - Admin: полный доступ (кроме Settings)
   - Support: чтение + работа с инцидентами
   - Read-only: только просмотр

## Скрипты для управления

- `backend/scripts/create_owner.py` - интерактивное создание Owner
- `backend/scripts/create_owner_auto.py` - автоматическое создание Owner
- `backend/scripts/apply_migrations.py` - применение миграций

## Безопасность

⚠️ **ВАЖНО:** Пароль по умолчанию небезопасен для продакшена. Обязательно измените его после первого входа!

Для смены пароля через скрипт можно использовать:
```python
from core.database import SessionLocal
from models.user import User
from services.auth_service import AuthService

db = SessionLocal()
user = db.query(User).filter(User.email == 'rail.tamaew@gmail.com').first()
user.password_hash = AuthService.hash_password('новый_безопасный_пароль')
db.commit()
db.close()
```




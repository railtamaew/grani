# Статус исправления API

**Дата:** 2025-12-22  
**Статус:** ⚠️ В процессе

## Выполненные исправления

1. ✅ Исправлена ошибка JWT: `jwt.JWTError` → `jwt.InvalidTokenError`
2. ✅ Добавлены недостающие поля в таблицу `servers`
3. ✅ Исправлен импорт моделей в `main.py` для правильной инициализации relationships
4. ✅ Использован raw SQL в `list_servers` для избежания проблем с relationships
5. ✅ Обновлен `get_current_user` для использования `noload` для relationships

## Текущие проблемы

1. ⚠️ API эндпоинт `/api/servers/` все еще возвращает ошибку "Неверный токен"
   - Токен создается и валидируется правильно
   - Проблема возникает при вызове `get_current_user` через API
   - Возможно, проблема в инициализации relationships при запросе User

## Следующие шаги

1. Проверить логи backend для точной ошибки
2. Исправить проблему с инициализацией relationships в User
3. Протестировать все эндпоинты API
4. Добавить сервер через API

## Команды для тестирования

```bash
# Получить токен
cd /opt/grani/backend
TOKEN=$(python3 get_admin_token.py rail.tamaew@gmail.com 2>&1 | grep "Token:" | awk '{print $2}')

# Тестировать список серверов
curl -H "Authorization: Bearer $TOKEN" http://localhost:8000/api/servers/

# Тестировать создание сервера
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"Test Server","ip_address":"45.12.132.94","country":"RU","wireguard_port":51820,"supported_protocols":["wireguard"],"is_local":false}' \
  http://localhost:8000/api/servers/

# Тестировать SSH подключение
curl -X POST -H "Authorization: Bearer $TOKEN" http://localhost:8000/api/servers/1/test-connection
```







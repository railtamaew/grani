# Как получить токен для авторизации

## ✅ Быстрый способ (рекомендуется)

Запустите скрипт на сервере:

```bash
cd /opt/grani/backend
python3 get_admin_token.py rail.tamaew@gmail.com
```

Скрипт выведет токен и примеры использования.

## 📋 Текущий токен для rail.tamaew@gmail.com

```
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3NjYzODgzNTYsInN1YiI6IjEifQ.1gX2eMhP2EKdsU2YvkmreezMpk5Sx9XSXCftsyHh24U
```

**Внимание:** Токен действителен 30 минут. Для получения нового токена запустите скрипт снова.

## 🔗 Использование токена

### 1. Просмотр кодов через веб-страницу:
```
https://api.granilink.com/codes?token=YOUR_TOKEN
```

Или для конкретного email:
```
https://api.granilink.com/codes?token=YOUR_TOKEN&email=rail.tamaew@gmail.com
```

### 2. API запрос через curl:
```bash
curl -H "Authorization: Bearer YOUR_TOKEN" \
     https://api.granilink.com/api/admin/auth-codes?email=rail.tamaew@gmail.com
```

### 3. Сохранить токен в переменную:
```bash
export ADMIN_TOKEN='YOUR_TOKEN'
curl -H "Authorization: Bearer $ADMIN_TOKEN" \
     https://api.granilink.com/api/admin/auth-codes
```

## 🔄 Получение нового токена

Токен истекает через 30 минут. Для получения нового:

```bash
cd /opt/grani/backend
python3 get_admin_token.py rail.tamaew@gmail.com
```

## 📝 Проверка токена

Проверить, что токен работает:

```bash
curl -H "Authorization: Bearer YOUR_TOKEN" \
     https://api.granilink.com/api/admin/me
```

Должен вернуть информацию о пользователе.







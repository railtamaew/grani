# Как получить токен для авторизации в админ-панели

## Способ 1: Через скрипт (рекомендуется)

```bash
cd /opt/grani/backend
python3 get_admin_token.py rail.tamaew@gmail.com
```

Скрипт выведет токен и инструкции по его использованию.

## Способ 2: Через API после авторизации по email

Если вы уже авторизовались через email (как rail.tamaew@gmail.com), токен был получен при успешной проверке кода.

Токен можно получить из ответа API `/api/auth/verify-code`:
```json
{
  "ok": true,
  "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
}
```

## Способ 3: Через мобильное приложение

После успешной авторизации токен сохраняется в мобильном приложении. Можно получить его из логов или через отладку.

## Использование токена

### 1. В URL для страницы просмотра кодов:
```
https://api.granilink.com/codes?token=YOUR_TOKEN
```

### 2. В HTTP заголовке для API запросов:
```bash
curl -H "Authorization: Bearer YOUR_TOKEN" \
     https://api.granilink.com/api/admin/auth-codes
```

### 3. В админ-панели React:
Токен автоматически сохраняется в localStorage после входа через форму логина.

## Проверка токена

Проверить, что токен работает:
```bash
curl -H "Authorization: Bearer YOUR_TOKEN" \
     https://api.granilink.com/api/admin/me
```

Должен вернуть информацию о пользователе.







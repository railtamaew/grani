# Настройка отправки email через Yandex Cloud Postbox

## Текущая конфигурация

### Настройки по умолчанию (закреплены в `backend/core/config.py`)

- **Email отправителя**: `support@granilink.com`
- **Имя отправителя**: `GRANI Account`
- **Endpoint**: `https://postbox.cloud.yandex.net` (устанавливается через переменную окружения `AWS_SES_ENDPOINT`)
- **Region**: `ru-central1` (устанавливается через переменную окружения `AWS_REGION`)

### Переменные окружения (.env)

Для работы с Yandex Cloud Postbox необходимо установить:

```env
USE_AWS_SES=true
AWS_ACCESS_KEY_ID=your_access_key
AWS_SECRET_ACCESS_KEY=your_secret_key
AWS_SES_ENDPOINT=https://postbox.cloud.yandex.net
AWS_REGION=ru-central1
AWS_SES_FROM_EMAIL=support@granilink.com
AWS_SES_FROM_NAME=GRANI Account
```

## Метод отправки email

### Используемый клиент и формат

- **Клиент**: `sesv2` (НЕ `ses`)
- **Endpoint**: `https://postbox.cloud.yandex.net`
- **Region**: `ru-central1`

### Формат запроса для sesv2

```python
response = ses_client.send_email(
    FromEmailAddress='"{from_name}" <{from_email}>',  # С именем в кавычках
    Destination={'ToAddresses': [to_email]},
    Content={
        'Simple': {
            'Subject': {'Data': subject, 'Charset': 'UTF-8'},
            'Body': {
                'Text': {'Data': text_body, 'Charset': 'UTF-8'},
                'Html': {'Data': html_body, 'Charset': 'UTF-8'}
            }
        }
    }
)
```

## Критические правила

### 1. Текстовый ответ = ОШИБКА

- Если Yandex Postbox возвращает текстовый ответ (ResponseParserError) - это **ОШИБКА**
- Текстовый ответ означает, что письмо **НЕ отправлено**
- **НЕ** считать текстовый ответ успехом, даже если есть request-id

### 2. XML ответ с MessageId = УСПЕХ

- Успешная отправка возвращает XML ответ с полем `MessageId`
- Только в этом случае письмо действительно отправлено

### 3. Формат отправителя

- Для Yandex Postbox используем формат: `"Имя" <email@domain.com>`
- Пример: `"GRANI Account" <support@granilink.com>`

### 4. НЕ использовать старый формат `ses` client

- Старый формат с `Source` и `Message` НЕ работает правильно
- Всегда использовать `sesv2` с форматом `FromEmailAddress` и `Content.Simple`

## Реализация

### Файлы

- **`backend/aws_ses_service.py`**: Определение Yandex Postbox (проверка endpoint на `postbox.cloud.yandex.net`), использование `sesv2` client для Yandex Postbox, стандартный `ses` client для AWS SES
- **`backend/services/email_service.py`**: Функции создания текстового и HTML содержимого письма

### Логика определения Yandex Postbox

```python
endpoint = settings.aws_ses_endpoint.rstrip('/')
is_yandex_postbox = endpoint and 'postbox.cloud.yandex.net' in endpoint

if is_yandex_postbox:
    ses_client = boto3.client('sesv2', ...)  # Используем sesv2
else:
    ses_client = boto3.client('ses', ...)    # Используем стандартный ses
```

## Шаблон письма

### HTML шаблон (закреплен в `backend/services/email_service.py`)

- **Градиентный заголовок**: от `#032C3C` до `#E69B6E` (135deg)
- **Заголовок "GRANI"**: белым цветом, размер 28px, жирный
- **Заголовок "Код подтверждения"**: размер 24px
- **Большой блок с кодом**: размер 36px, letter-spacing 12px
- **Текст**: "Здравствуйте! Вы запросили код подтверждения для входа в приложение GRANI. Ниже — ваш код:"
- **Время действия**: "Код действителен 10 минут."
- **Предупреждение**: "Если вы не запрашивали этот код — просто проигнорируйте письмо."
- **Копирайт**: "© 2026 GRANI. Все права защищены."

### Текстовая версия

Содержит тот же текст, что и HTML версия, но без форматирования.

## API эндпоинты

### Отправка кода

**Эндпоинт**: `POST /api/auth/send-code`

**Параметры**:
```json
{
  "email": "user@example.com"
}
```

**Ответ**:
```json
{
  "ok": true,
  "message": "Код отправлен на email"
}
```

### Проверка кода

**Эндпоинт**: `POST /api/auth/verify-code`

**Параметры**:
```json
{
  "email": "user@example.com",
  "code": "1234"
}
```

**Ответ при успехе**:
```json
{
  "ok": true,
  "token": "jwt_token_here",
  "user": {
    "id": 1,
    "email": "user@example.com",
    "name": "user",
    "is_verified": true,
    "created_at": "2025-01-01T00:00:00",
    "is_blocked": false
  },
  "trialSecondsLeft": 604800,
  "hasActiveSubscription": false
}
```

## Rate limiting и ограничения

### Первый запрос

- Код можно запросить сразу при вводе email на экране авторизации
- Эндпоинт: `POST /api/auth/send-code`

### Повторный запрос

- Повторный запрос кода доступен через определенное время (rate limiting)
- В приложении есть таймер обратного отсчета (`secondsUntilCodeResend`)
- Пользователь видит, сколько секунд осталось до возможности повторной отправки
- Минимальный интервал между запросами: обычно 30 секунд (настраивается на сервере)

### Ограничения

- **Дневной лимит**: Есть дневной лимит на количество кодов (`dailyCodeRemaining`)
- **При превышении лимита**: Запрос будет отклонен с ошибкой 429
- **Время действия кода**: 10 минут (`EMAIL_CODE_TTL_MINUTES = 10`)
- **Максимум попыток**: 5 попыток ввода кода (`MAX_VERIFICATION_ATTEMPTS = 5`)

### Логика в приложении

- Экран ввода кода (`auth_code_screen.dart`) показывает таймер
- Кнопка "Отправить код повторно" активна только когда `_secondsLeft == 0`
- При ошибке проверки кода можно запросить новый код (если не превышен лимит попыток)

## Важные замечания

1. **НЕ обрабатывать ResponseParserError как успех**
   - Текстовый ответ всегда означает ошибку
   - Проверять наличие `MessageId` в ответе для подтверждения успеха

2. **Всегда использовать sesv2 для Yandex Postbox**
   - Не использовать старый `ses` client
   - Не использовать `SendRawEmail` для Yandex Postbox

3. **Правильный формат отправителя**
   - Всегда включать имя отправителя в кавычках
   - Формат: `"GRANI Account" <support@granilink.com>`

## Проверка работы

### Тестовый эндпоинт

**Эндпоинт**: `POST /api/auth/test-email`

**Параметры**:
```json
{
  "email": "test@example.com",
  "code": "9999"
}
```

**Ответ**:
```json
{
  "ok": true,
  "message": "Тестовое письмо отправлено на test@example.com",
  "code": "9999",
  "email_sent": true
}
```

### Логирование

Все операции логируются с префиксами:
- `[aws_ses_service]` - логи отправки через SES/Postbox
- `[email_service]` - логи сервиса email
- `[send-code]` - логи эндпоинта отправки кода
- `[verify-code]` - логи эндпоинта проверки кода

## Быстрый старт

1. Убедитесь, что в `.env` файле установлены все необходимые переменные (см. раздел "Переменные окружения")
2. Перезапустите backend сервер
3. Проверьте работу через тестовый эндпоинт `/api/auth/test-email`
4. Проверьте логи на наличие ошибок

## Файлы конфигурации

- **`backend/core/config.py`**: Настройки по умолчанию (закреплены)
- **`backend/aws_ses_service.py`**: Реализация отправки через SES/Postbox
- **`backend/services/email_service.py`**: Создание содержимого письма
- **`backend/api/auth.py`**: API эндпоинты для отправки и проверки кода

## Связанная документация

**Основной документ по email авторизации:** `AUTH_EMAIL_COMPLETE.md`

Этот документ (`EMAIL_SETUP.md`) описывает техническую настройку отправки email через Yandex Cloud Postbox. Полная документация по email авторизации, включая API эндпоинты, поток авторизации и UI/UX правила, находится в `AUTH_EMAIL_COMPLETE.md`.



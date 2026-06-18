# Подключение к базе данных

## Почему «password authentication failed for user granivpn_user»

PostgreSQL запущен в Docker (контейнер `granivpn_postgres`, порт 5432). Пароль пользователя `granivpn_user` задаётся при старте контейнера переменной **POSTGRES_PASSWORD** из окружения docker-compose.

Скрипты и приложение, запускаемые **на хосте** (не в Docker), берут строку подключения из **backend**: переменная **DATABASE_URL** в `backend/.env` или дефолт в `core/config.py`.

Если пароль в DATABASE_URL не совпадает с паролем, под которым был создан контейнер Postgres, возникает ошибка:  
`password authentication failed for user "granivpn_user"`.

## Что проверить

1. **Пароль контейнера Postgres**  
   Задаётся в `server-config/.env` (или в том env-файле, откуда запускается docker-compose):
   - переменная `POSTGRES_PASSWORD`

2. **Строка подключения для backend**  
   В `backend/.env` должна быть переменная **DATABASE_URL**:
   - хост: **localhost** (скрипты с хоста подключаются к порту 5432 на хосте, который проброшен из контейнера).
   - пользователь: `granivpn_user`
   - пароль: **тот же**, что и в `POSTGRES_PASSWORD` при запуске контейнера.
   - база: `granivpn`

   Пример (подставьте свой пароль):
   ```bash
   DATABASE_URL=postgresql://granivpn_user:ВАШ_ПАРОЛЬ@localhost:5432/granivpn
   ```

3. **Единый пароль**  
   Значение пароля в `backend/.env` (в DATABASE_URL) и в `server-config/.env` (POSTGRES_PASSWORD) должно совпадать. Иначе контейнер создан с одним паролем, а backend подключается с другим.

## Быстрое исправление

Если Postgres поднят из `server-config` с `server-config/.env`:

- Откройте `server-config/.env` и посмотрите `POSTGRES_PASSWORD`.
- В `backend/.env` задайте:
  ```bash
  DATABASE_URL=postgresql://granivpn_user:<тот_же_пароль>@localhost:5432/granivpn
  ```
- Перезапускать контейнеры не нужно — пароль в БД уже задан при первом запуске тома.

Если вы меняете пароль в `server-config/.env` и пересоздаёте контейнер/том — тогда нужно обновить и DATABASE_URL в `backend/.env`.

## Проверка подключения

После настройки:

```bash
cd backend
python3 scripts/apply_user_vpn_connections_migration.py
```

При успехе будет сообщение об применении миграции. При ошибке аутентификации — ещё раз сверьте пароль в DATABASE_URL и POSTGRES_PASSWORD.

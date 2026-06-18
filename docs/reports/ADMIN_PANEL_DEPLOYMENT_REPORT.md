# Отчет о развертывании админ-панели GRANI VPN

**Дата создания:** 24 декабря 2025  
**Версия:** 1.0  
**Статус:** Частично развернуто, требует доработки

---

## 📋 Содержание

1. [Выполненные работы](#выполненные-работы)
2. [Текущий статус](#текущий-статус)
3. [Проблемы и их причины](#проблемы-и-их-причины)
4. [Что осталось сделать](#что-осталось-сделать)
5. [Инструкции по доработке](#инструкции-по-доработке)
6. [Проверочный чеклист](#проверочный-чеклист)

---

## ✅ Выполненные работы

### 1. Backend (API)

- ✅ Расширены модели базы данных (`User`, `Device`, `Subscription`, `Server`, `Protocol`, `TelemetryEvent`, `AuditLog`, `AdminLoginLog`)
- ✅ Созданы API эндпоинты:
  - `/api/admin/auth/login` - Вход в админ-панель
  - `/api/admin/auth/logout` - Выход
  - `/api/admin/auth/me` - Получение текущего пользователя
  - `/api/admin/users/*` - Управление пользователями
  - `/api/admin/servers/*` - Управление серверами
  - `/api/admin/protocols/*` - Управление протоколами
  - `/api/admin/incidents/*` - Управление инцидентами
  - `/api/admin/audit/*` - Просмотр логов аудита
- ✅ Реализована система RBAC (Role-Based Access Control) с ролями: Owner, Admin, Support, Read-only
- ✅ Настроен rate limiting для логина (10 попыток, блокировка на 15 минут)
- ✅ Реализовано логирование входов и действий администраторов
- ✅ Создан скрипт `create_owner_auto.py` для создания Owner пользователя

### 2. Frontend (Админ-панель)

- ✅ Создан React SPA с Material-UI
- ✅ Реализованы страницы:
  - Login (страница входа)
  - Dashboard (дашборд)
  - Users (пользователи)
  - Servers (серверы)
  - Protocols (протоколы)
  - Incidents (инциденты)
  - Payments (платежи)
  - Audit Log (аудит)
  - Settings (настройки, только для Owner)
- ✅ Настроена тема с брендингом GRANI
- ✅ Реализована маршрутизация с защищенными маршрутами
- ✅ Настроена интеграция с Redux для управления состоянием

### 3. Инфраструктура

- ✅ Установлен и настроен Nginx
- ✅ Настроены DNS записи:
  - `granilink.com` → 159.223.199.122
  - `admin.granilink.com` → 159.223.199.122
  - `api.granilink.com` → 159.223.199.122
  - `app.granilink.com` → 159.223.199.122
- ✅ Настроена конфигурация Nginx для отдачи статических файлов админ-панели
- ✅ Создана структура конфигурационных файлов в `/opt/grani/server-config/nginx/`

### 4. База данных

- ✅ Создан SQL скрипт миграции `migrations/add_admin_features.sql`
- ✅ Добавлены таблицы: `protocols`, `telemetry_events`, `audit_logs`, `admin_login_logs`
- ✅ Расширены существующие таблицы новыми полями

---

## 📊 Текущий статус

### Что работает:

1. ✅ **Backend API** - запущен и доступен на порту 8000
2. ✅ **Nginx** - установлен и настроен, отдает статические файлы
3. ✅ **DNS** - все домены настроены правильно
4. ✅ **Файлы админ-панели** - размещены в `/opt/grani/admin-panel/build/`
5. ✅ **Доступность** - админ-панель доступна по адресу `http://admin.granilink.com/`

### Что НЕ работает:

1. ❌ **Интерфейс не отображается** - страница загружается, но форма входа не видна
2. ❌ **JavaScript возможно не выполняется** - может быть проблема с загрузкой JS файлов
3. ❌ **API URL может быть неправильным** - в сборке используется `http://94.131.107.227:8000`

---

## 🔍 Проблемы и их причины

### Проблема 1: Админ-панель не отображается

**Симптомы:**
- Страница загружается (HTTP 200)
- HTML отдается корректно
- Но интерфейс (форма входа) не виден

**Возможные причины:**
1. JavaScript файлы не загружаются (CORS, пути, права доступа)
2. API запросы падают из-за неправильного API URL
3. React приложение падает с ошибкой при инициализации
4. Отсутствуют CSS файлы или стили не применяются
5. Проблема с путями к статическим файлам

**Диагностика:**
```bash
# Проверить доступность JS файлов
curl -I http://admin.granilink.com/static/js/main.b3c18ea5.js

# Проверить логи Nginx
sudo tail -f /var/log/nginx/error.log

# Проверить права доступа
ls -la /opt/grani/admin-panel/build/static/
```

### Проблема 2: API URL в сборке устарел

**Текущее значение:** `http://94.131.107.227:8000`  
**Должно быть:** `http://api.granilink.com` или `http://granilink.com/api`

**Решение:** Пересобрать админ-панель с правильным API URL.

---

## 🔧 Что осталось сделать

### Критичные задачи (для работы админ-панели):

1. **Проверить загрузку статических файлов**
   - Убедиться, что JS и CSS файлы доступны
   - Проверить пути в `index.html`
   - Проверить права доступа на файлы

2. **Исправить API URL**
   - Пересобрать админ-панель с `REACT_APP_API_URL=http://api.granilink.com`
   - Или настроить проксирование API через Nginx

3. **Проверить консоль браузера**
   - Открыть DevTools (F12)
   - Проверить вкладку Console на наличие ошибок
   - Проверить вкладку Network на наличие failed запросов

4. **Проверить логи Nginx**
   - Искать ошибки 404 для статических файлов
   - Проверить CORS заголовки для API

5. **Создать Owner пользователя в БД**
   ```bash
   cd /opt/grani/backend
   python scripts/create_owner_auto.py
   ```

6. **Применить миграции БД**
   ```bash
   cd /opt/grani/backend
   python scripts/apply_migrations.py
   ```

### Важные задачи (для полноценной работы):

7. **Настроить SSL сертификаты**
   - Установить certbot
   - Получить сертификаты для всех доменов
   - Обновить Nginx конфигурацию для HTTPS

8. **Настроить CORS на backend**
   - Разрешить запросы с `http://admin.granilink.com`
   - Настроить правильные заголовки

9. **Проверить Redis для rate limiting**
   - Убедиться, что Redis запущен
   - Проверить подключение из backend

10. **Тестирование функциональности**
    - Проверить вход в админ-панель
    - Проверить все CRUD операции
    - Проверить RBAC (разные роли)

---

## 📝 Инструкции по доработке

### Шаг 1: Диагностика проблемы с отображением

```bash
# 1. Проверить загрузку JS файлов
curl -I http://admin.granilink.com/static/js/main.b3c18ea5.js

# 2. Проверить права доступа
sudo ls -la /opt/grani/admin-panel/build/static/

# 3. Проверить логи Nginx в реальном времени
sudo tail -f /var/log/nginx/error.log

# 4. Открыть в браузере с DevTools (F12)
# - Проверить Console на ошибки
# - Проверить Network на failed requests
```

### Шаг 2: Пересборка админ-панели с правильным API URL

```bash
cd /opt/grani/admin-panel

# Установить зависимости (если нужно)
npm install

# Создать .env файл с правильным API URL
echo "REACT_APP_API_URL=http://api.granilink.com" > .env

# Пересобрать
npm run build

# Установить права
sudo chown -R www-data:www-data /opt/grani/admin-panel/build
sudo chmod -R 755 /opt/grani/admin-panel/build

# Перезагрузить Nginx
sudo systemctl reload nginx
```

### Шаг 3: Настройка API проксирования через Nginx

В файле `/opt/grani/server-config/nginx/granivpn-http-only.conf` уже настроено проксирование `/api` на backend. Убедитесь, что:

1. Backend доступен на `127.0.0.1:8000`
2. В админ-панели используется относительный путь `/api` вместо абсолютного URL

### Шаг 4: Применение миграций БД

```bash
cd /opt/grani/backend

# Вариант 1: Через Python скрипт
python scripts/apply_migrations.py

# Вариант 2: Через psql напрямую
psql -U granivpn_user -d granivpn -f migrations/add_admin_features.sql
```

### Шаг 5: Создание Owner пользователя

```bash
cd /opt/grani/backend

# Установить переменные окружения
export OWNER_EMAIL=rail.tamaew@gmail.com
export OWNER_PASSWORD=ChangeThisPassword123!

# Запустить скрипт
python scripts/create_owner_auto.py
```

### Шаг 6: Настройка SSL (опционально, но рекомендуется)

```bash
# Установить certbot
sudo apt install certbot python3-certbot-nginx

# Получить сертификаты
sudo certbot --nginx -d granilink.com -d www.granilink.com
sudo certbot --nginx -d admin.granilink.com
sudo certbot --nginx -d api.granilink.com

# Обновить конфигурацию Nginx для HTTPS
sudo cp /opt/grani/server-config/nginx/granivpn-servers.conf /etc/nginx/sites-available/granivpn-servers
sudo nginx -t
sudo systemctl reload nginx
```

---

## ✅ Проверочный чеклист

### Инфраструктура:
- [ ] Nginx установлен и запущен
- [ ] DNS записи настроены и работают
- [ ] Статические файлы доступны
- [ ] Права доступа установлены правильно

### Backend:
- [ ] Backend запущен на порту 8000
- [ ] Миграции БД применены
- [ ] Owner пользователь создан
- [ ] Redis запущен (для rate limiting)
- [ ] CORS настроен правильно

### Frontend:
- [ ] Админ-панель собрана (`npm run build`)
- [ ] API URL настроен правильно
- [ ] Статические файлы загружаются без ошибок
- [ ] JavaScript выполняется без ошибок в консоли

### Функциональность:
- [ ] Страница входа отображается
- [ ] Можно войти с учетными данными Owner
- [ ] Дашборд загружается после входа
- [ ] Все страницы доступны
- [ ] API запросы работают

### Безопасность:
- [ ] Rate limiting работает
- [ ] RBAC работает (разные роли)
- [ ] Audit log записывает действия
- [ ] SSL сертификаты установлены (опционально)

---

## 🔍 Диагностика текущей проблемы

### Текущая ситуация (24.12.2025)

**Проблема:** Админ-панель не отображается - не видно формы входа, хотя страница загружается (HTTP 200).

**Что проверено:**
- ✅ HTML файл отдается корректно (`/opt/grani/admin-panel/build/index.html`)
- ✅ JS файл загружается (HTTP 200, 955KB, `/static/js/main.b3c18ea5.js`)
- ✅ Права доступа правильные (www-data:www-data, 755)
- ✅ Nginx конфигурация правильная (`try_files $uri $uri/ /index.html`)
- ❌ **В JS файле используется устаревший API URL:** `http://94.131.107.227:8000`
- ❓ **Требуется проверка:** консоль браузера на наличие JavaScript ошибок

### Шаги для диагностики:

1. **Откройте админ-панель в браузере:** http://admin.granilink.com
2. **Откройте DevTools (F12)**
3. **Проверьте вкладку Console:**
   - Есть ли красные ошибки?
   - Какие сообщения об ошибках?
4. **Проверьте вкладку Network:**
   - Загружаются ли все файлы (JS, CSS)?
   - Есть ли failed requests (404, 500)?
   - Какие запросы к API делаются при загрузке?

### Возможные причины:

1. **JavaScript ошибка при инициализации React**
   - React пытается сделать API запрос с неправильным URL
   - CORS ошибка
   - Ошибка при загрузке конфигурации

2. **Проблема с путями к статическим файлам**
   - Хотя JS файл загружается, могут быть проблемы с другими ресурсами

3. **Проблема с API URL**
   - Приложение пытается подключиться к `http://94.131.107.227:8000`
   - Backend может быть недоступен по этому адресу
   - Нужно пересобрать с правильным API URL или настроить проксирование

### Следующие шаги:

1. **Пересобрать админ-панель с правильным API URL:**
   ```bash
   cd /opt/grani/admin-panel
   export REACT_APP_API_URL=http://api.granilink.com
   npm run build
   sudo chown -R www-data:www-data build
   sudo systemctl reload nginx
   ```

2. **Или использовать относительный путь `/api`** и настроить проксирование через Nginx (уже настроено)

3. **Проверить, что backend доступен:**
   ```bash
   curl http://localhost:8000/health
   curl http://api.granilink.com/health
   ```

---

## 🐛 Отладка проблем

### Проблема: "Белая страница" или ничего не отображается

1. Откройте DevTools (F12) в браузере
2. Проверьте вкладку **Console** - там будут ошибки JavaScript
3. Проверьте вкладку **Network**:
   - Есть ли failed requests (красные)?
   - Загружаются ли JS и CSS файлы?
   - Какие коды ответов (200, 404, 500)?

### Проблема: "404 Not Found" для статических файлов

```bash
# Проверить пути в Nginx конфигурации
sudo cat /etc/nginx/sites-enabled/granivpn-http-only | grep -A 10 "location /static"

# Проверить существование файлов
ls -la /opt/grani/admin-panel/build/static/js/

# Проверить права доступа
sudo chown -R www-data:www-data /opt/grani/admin-panel/build
sudo chmod -R 755 /opt/grani/admin-panel/build
```

### Проблема: "CORS error" в консоли браузера

1. Проверить настройки CORS в FastAPI backend
2. Убедиться, что `CORS_ORIGINS` включает `http://admin.granilink.com`
3. Проверить, что API запросы идут через `/api` (относительный путь)

### Проблема: "401 Unauthorized" при попытке входа

1. Проверить, что Owner пользователь создан:
   ```bash
   cd /opt/grani/backend
   python scripts/create_owner_auto.py
   ```

2. Проверить, что backend запущен:
   ```bash
   curl http://localhost:8000/health
   ```

3. Проверить логи backend на наличие ошибок

---

## 📁 Структура файлов

```
/opt/grani/
├── backend/
│   ├── api/
│   │   ├── admin_auth.py          # API для аутентификации
│   │   ├── admin.py                # API для управления пользователями/серверами
│   │   ├── admin_protocols.py      # API для протоколов
│   │   ├── admin_incidents.py      # API для инцидентов
│   │   ├── admin_audit.py          # API для аудита
│   │   └── admin_settings.py       # API для настроек
│   ├── models/
│   │   ├── user.py                 # Расширенная модель пользователя
│   │   ├── protocol.py             # Модель протоколов
│   │   ├── telemetry.py            # Модель телеметрии
│   │   ├── audit_log.py            # Модель аудита
│   │   └── admin_login_log.py      # Модель логов входа
│   ├── services/
│   │   ├── admin_auth_service.py   # Сервис аутентификации
│   │   └── telemetry_service.py    # Сервис телеметрии
│   ├── scripts/
│   │   ├── create_owner_auto.py    # Создание Owner пользователя
│   │   └── apply_migrations.py     # Применение миграций
│   └── migrations/
│       └── add_admin_features.sql  # SQL миграции
│
├── admin-panel/
│   ├── build/                      # Собранная версия (раздается Nginx)
│   │   ├── index.html
│   │   └── static/
│   │       ├── js/
│   │       └── css/
│   ├── src/
│   │   ├── pages/                  # Страницы админ-панели
│   │   ├── components/             # Компоненты
│   │   ├── services/               # API сервисы
│   │   └── store/                  # Redux store
│   └── package.json
│
└── server-config/
    └── nginx/
        ├── granivpn-http-only.conf  # HTTP конфигурация (текущая)
        ├── granivpn-servers.conf    # HTTPS конфигурация (для SSL)
        └── granivpn-upstreams.conf  # Upstream блоки
```

---

## 🔗 Полезные ссылки

- **Админ-панель:** http://admin.granilink.com
- **API:** http://api.granilink.com (или http://granilink.com/api)
- **Логи Nginx:** `/var/log/nginx/error.log` и `/var/log/nginx/access.log`
- **Backend логи:** смотря где запущен (обычно в stdout/stderr)

---

## 📞 Контакты для поддержки

При возникновении проблем:

1. Проверьте этот отчет
2. Проверьте логи (Nginx, Backend)
3. Проверьте консоль браузера (DevTools)
4. Убедитесь, что все шаги из раздела "Что осталось сделать" выполнены

---

**Дата последнего обновления:** 24 декабря 2025  
**Версия документа:** 1.0


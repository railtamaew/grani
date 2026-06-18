# GraniVPN Admin Panel

Админ панель для управления VPN-сервисом GraniVPN на React + TypeScript.

## Технологии

- **React 18** - Основной фреймворк
- **TypeScript** - Типизация
- **Material-UI (MUI)** - UI компоненты
- **Redux Toolkit** - Управление состоянием
- **React Query** - Кэширование и управление серверным состоянием
- **React Router** - Маршрутизация
- **React Hook Form** - Управление формами
- **Yup** - Валидация форм
- **Recharts** - Графики и диаграммы
- **Axios** - HTTP клиент

## Установка

```bash
# Установка зависимостей
npm install

# Запуск в режиме разработки
npm start

# Сборка для продакшена
npm run build

# Запуск тестов
npm test
```

## Конфигурация для разработки

- Файл `.env.development` отключает проверку хоста dev-сервера (`DANGEROUSLY_DISABLE_HOST_CHECK=true`), чтобы запуск при `HOST=0.0.0.0` не падал с ошибкой `allowedHosts`.
- Для работы с бэкендом на другом порту задайте переменную окружения при запуске:
  ```bash
  REACT_APP_API_URL=http://127.0.0.1:8010 npm start
  ```
  В production URL задаётся через `window.__GRANI_CONFIG__.apiBaseUrl` или `runtime-config.js`.

## Структура проекта

```
src/
├── components/          # Переиспользуемые компоненты
│   ├── Layout/         # Компоненты макета
│   └── ProtectedRoute.tsx
├── pages/              # Страницы приложения
│   ├── LoginPage.tsx
│   ├── DashboardPage.tsx
│   ├── UsersPage.tsx
│   ├── ServersPage.tsx
│   └── PaymentsPage.tsx
├── services/           # API сервисы
│   ├── api.ts
│   ├── authService.ts
│   ├── dashboardService.ts
│   ├── usersService.ts
│   ├── serversService.ts
│   └── paymentsService.ts
├── store/              # Redux store
│   ├── index.ts
│   └── slices/
│       ├── authSlice.ts
│       ├── dashboardSlice.ts
│       ├── usersSlice.ts
│       ├── serversSlice.ts
│       └── paymentsSlice.ts
├── theme.ts            # Тема Material-UI
├── App.tsx             # Главный компонент
└── index.tsx           # Точка входа
```

## Функциональность

### 🔐 Аутентификация
- Вход в систему с email/паролем
- JWT токены
- Защищенные маршруты
- Автоматический редирект при истечении токена

### 📊 Дашборд
- Общая статистика системы
- Количество пользователей, серверов, устройств
- Графики подключений
- Статус WireGuard
- Доходы и платежи

### 👥 Управление пользователями
- Список всех пользователей
- Поиск по email/имени
- Блокировка/разблокировка пользователей
- Просмотр деталей пользователя
- Информация о подписках и устройствах
- Пагинация

### 🖥️ Управление серверами
- Список VPN серверов
- Добавление новых серверов
- Редактирование существующих
- Включение/отключение серверов
- Мониторинг здоровья серверов
- Статистика подключений

### 💳 Управление платежами
- История всех платежей
- Фильтрация по статусу
- Поиск по email пользователя
- Детальная информация о платежах
- Статистика доходов

## API интеграция

Админ панель интегрируется с backend API через следующие endpoints:

- `/api/auth/*` - Аутентификация
- `/api/admin/dashboard/*` - Статистика дашборда
- `/api/admin/users/*` - Управление пользователями
- `/api/admin/servers/*` - Управление серверами
- `/api/admin/payments/*` - Управление платежами

## Развертывание

### Docker

```bash
# Сборка образа
docker build -t granivpn-admin .

# Запуск контейнера
docker run -p 3000:3000 granivpn-admin
```

### Nginx

```nginx
server {
    listen 80;
    server_name admin.granivpn.com;

    location / {
        root /var/www/admin-panel;
        try_files $uri $uri/ /index.html;
    }

    location /api {
        proxy_pass http://backend:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

## Переменные окружения

```env
REACT_APP_API_URL=http://localhost:8000
REACT_APP_ENVIRONMENT=development
```

## Безопасность

- Все API запросы защищены JWT токенами
- Автоматический logout при истечении токена
- Валидация всех форм на клиенте
- Защищенные маршруты для неавторизованных пользователей

## Мониторинг

- Логирование ошибок
- Отслеживание производительности
- Мониторинг состояния API
- Уведомления о критических ошибках

## Разработка

### Добавление новой страницы

1. Создайте компонент в `src/pages/`
2. Добавьте маршрут в `src/App.tsx`
3. Добавьте пункт меню в `src/components/Layout/Sidebar.tsx`
4. Создайте Redux slice если нужно
5. Добавьте API сервис

### Стилизация

Используйте Material-UI компоненты и тему в `src/theme.ts`. Для кастомных стилей используйте `sx` prop или `styled` компоненты.

### Тестирование

```bash
# Запуск тестов
npm test

# Покрытие кода
npm test -- --coverage

# E2E тесты (если настроены)
npm run test:e2e
```

## Лицензия

MIT License

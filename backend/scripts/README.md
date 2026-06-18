# Backend Scripts

Этот каталог содержит вспомогательные скрипты для управления и диагностики VPN сервиса.

## Категории скриптов

### 🛠️ Утилиты установки и настройки
- `create_tables.py` - Создание всех таблиц в БД
- `apply_migrations.py` - Применение миграций БД
- `apply_vpn_monitoring_migration.py` - Применение миграции мониторинга VPN
- `setup_server_protocols.py` - Настройка протоколов на серверах
- `setup_vpn_server.py` - Настройка VPN сервера
- `setup_xray_server.py` - Настройка Xray сервера
- `setup_xray_stats_api.py` - Настройка Xray Stats API
- `enable_all_protocols.py` - Включение всех протоколов на серверах

### 👤 Управление пользователями
- `create_owner.py` - Создание владельца системы
- `create_owner_auto.py` - Автоматическое создание владельца
- `create_trial_subscription.py` - Создание триальной подписки

### 🔍 Диагностика и проверка
- `check_servers_status.py` - Проверка статуса серверов
- `check_servers_simple.py` - Простая проверка серверов
- `check_server_protocols.py` - Проверка протоколов на серверах
- `check_protocols_readiness.py` - Проверка готовности протоколов
- `check_user_connection_status.py` - Проверка статуса подключения пользователя
- `check_user_token.py` - Проверка токена пользователя
- `check_xray_status.py` - Проверка статуса Xray
- `check_xray_logs.py` - Проверка логов Xray
- `check_client_traffic.py` - Проверка трафика клиента
- `check_hungary_xray.py` - Проверка Xray на сервере в Венгрии
- `check_routing_issue.py` - Проверка проблем с маршрутизацией
- `diagnose_wireguard_server.py` - Диагностика WireGuard сервера
- `diagnose_xray_connection.py` - Диагностика Xray подключения
- `verify_server_setup.py` - Проверка настройки сервера

### 🐛 Отладка
- `debug_traffic.py` - Отладка трафика
- `debug_xray_client_creation.py` - Отладка создания Xray клиента

### 🔧 Исправление проблем
- `fix_wireguard_config.py` - Исправление конфигурации WireGuard
- `fix_xray_config_path.py` - Исправление пути к конфигурации Xray
- `fix_xray_connection_issues.py` - Исправление проблем подключения Xray
- `fix_xray_duplicates.py` - Исправление дубликатов Xray
- `fix_xray_port.py` - Исправление порта Xray
- `fix_xray_service.py` - Исправление сервиса Xray
- `fix_routing.py` - Исправление маршрутизации
- `fix_traffic_routing.py` - Исправление маршрутизации трафика
- `check_and_fix_server.py` - Проверка и исправление сервера

### 🧪 Тестирование
- `test_all_protocols.py` - Тестирование всех протоколов
- `test_registration_flow.py` - Тестирование процесса регистрации
- `test_servers_api.py` - Тестирование API серверов
- `test_ssh_connection.py` - Тестирование SSH подключения
- `test_token_servers.py` - Тестирование токенов и серверов
- `test_xray_client_creation.py` - Тестирование создания Xray клиента
- `test_xray_setup.py` - Тестирование настройки Xray
- `test_xray_stats.py` - Тестирование статистики Xray
- `quick_test_xray.py` - Быстрый тест Xray
- `vpn_tester.py` - Тестер VPN

### 📤 Экспорт и импорт
- `export_client_configs.py` - Экспорт конфигураций клиентов

### 🔄 Обновление
- `update_server_xray_port.py` - Обновление порта Xray на сервере
- `update_wg_config_rules.py` - Обновление правил конфигурации WireGuard
- `add_protocols_to_servers.py` - Добавление протоколов к серверам

### 🧹 Очистка
- `clear_servers_cache.py` - Очистка кэша серверов
- `force_disconnect_and_connect_xray.py` - Принудительное отключение и подключение Xray

### 📚 Документация
- `README_VPN_TESTER.md` - Документация по VPN тестеру
- `xray_connection_summary.md` - Сводка по подключению Xray

## Использование

Большинство скриптов можно запустить напрямую:

```bash
cd /opt/grani/backend
python3 scripts/script_name.py
```

Некоторые скрипты требуют аргументов - проверьте документацию в начале файла.

## Архив

Старые или временные скрипты перемещены в `archive/` для сохранения истории, но они не используются в продакшене.

## Примечания

- ⚠️ **ВНИМАНИЕ**: Некоторые скрипты могут изменять конфигурацию серверов или данные в БД
- Всегда делайте резервные копии перед запуском скриптов, изменяющих данные
- Тестовые скрипты можно запускать безопасно, но они могут создавать тестовые данные

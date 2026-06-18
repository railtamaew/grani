# Глубокий анализ бэкенда GRANI (инвентарь + Celery + фокус на производительности)

Документ сгенерирован для ревизии: **неудовлетворительные показатели работы** API часто связаны не с «одной кнопкой», а с **слоем очередей**, **фоновой нагрузкой на БД/Redis**, **SSH на VPN-нодах** и **лимитами на границе (Nginx)**. Ниже — полный реестр скриптов и задач Celery; используйте его как чеклист при профилировании.

---

## 1. Реестр задач Celery (имена в брокере)

| Имя задачи (`name=`) | Файл | Очередь | В Beat? | Период / триггер |
|---------------------|------|---------|---------|------------------|
| `vpn.check_subscription_expiry` | `services/tasks/vpn_tasks.py` | default (маршрут `vpn_tasks.*` → **vpn**) | Да | 3600 с |
| `vpn.apply_xray_config` | `services/tasks/vpn_tasks.py` | vpn | Нет | `delay()` из `xray_manager` после create-client |
| `vpn.save_client_logs` | `services/tasks/client_logs_tasks.py` | default | Нет | `delay()` из `api/client_logs.py` |
| `notifications.send_subscription_expiry_warning` | `services/tasks/notification_tasks.py` | default | Да | ежедневно 09:00 UTC |
| `notifications.check_trial_expiry` | `services/tasks/notification_tasks.py` | default | Да | 900 с |
| `server.update_server_load` | `services/tasks/server_monitoring_tasks.py` | monitoring | Да | **30 с** |
| `server.check_server_health` | `services/tasks/server_monitoring_tasks.py` | monitoring | Да | 60 с |
| `server.collect_protocol_stats` | `services/tasks/server_monitoring_tasks.py` | monitoring | Да | полночь |
| `server.update_provider_stats` | `services/tasks/server_monitoring_tasks.py` | monitoring | Да | 300 с |
| `server.collect_server_error_logs` | `services/tasks/server_monitoring_tasks.py` | monitoring | Да | 120 с |

**Очереди (актуально):** в `services/celery_app.py` маршрутизация задаётся по **имени задачи**: `vpn.check_subscription_expiry` и `vpn.apply_xray_config` → очередь `vpn`; `vpn.save_client_logs` → `default`; `server.*` → `monitoring`; `notifications.*` → `default`. Воркер должен слушать `-Q default,vpn,monitoring`.

**Риск для latency API:** задачи **monitoring** каждые 30–120 с дергают БД и внешние проверки; при **низком `concurrency`** возможна очередь на `monitoring` / конкуренция с другими задачами. Имеет смысл смотреть длину очередей Redis и время выполнения задач.

---

## 2. Чеклист скриптов `backend/scripts/` (86 файлов)

Первая колонка — путь относительно `backend/`, вторая — первая строка module docstring или краткое назначение.

| Скрипт | Назначение (кратко) |
|--------|---------------------|
| `scripts/add_protocols_to_servers.py` | Добавляет поддерживаемые протоколы к серверам для тестирования. |
| `scripts/apply_device_fingerprint_migration.py` | Миграция колонки `device_fingerprint` для resolve после переустановки. |
| `scripts/apply_migrations.py` | Применение миграций БД. |
| `scripts/apply_user_vpn_connections_migration.py` | Миграция `user_vpn_connections`. |
| `scripts/apply_vpn_monitoring_migration.py` | Миграция мониторинга VPN. |
| `scripts/archive/boring_https_poc_client.py` | PoC Boring HTTPS (клиент). |
| `scripts/archive/boring_https_tun_helper.py` | TUN-хелпер Boring HTTPS gateway. |
| `scripts/bypass_lab_adaptive_selector.py` | PoC adaptive strategy / зонды. |
| `scripts/bypass_lab_bootstrap_poc.py` | PoC bootstrap / DoH. |
| `scripts/bypass_lab_capture_traffic.py` | Лаборатория: pcap / анализ обхода. |
| `scripts/bypass_lab_mimicry_poc.py` | PoC traffic mimicry / TLS. |
| `scripts/bypass_lab_tunnel_client.py` | Тестовый клиент туннеля Boring HTTPS. |
| `scripts/check_and_fix_server.py` | Проверка и исправление WireGuard: пир, forwarding, iptables. |
| `scripts/check_client_config_4443.py` | Проверка клиентского конфига для конкретного UUID (жёстко заданный кейс). |
| `scripts/check_client_logs_status.py` | Проверка системы логирования клиентов. |
| `scripts/check_client_traffic.py` | Проверка трафика клиента на сервере. |
| `scripts/check_hungary_xray.py` | Проверка HU-сервера и Xray. |
| `scripts/check_protocols_readiness.py` | Готовность протоколов на серверах. |
| `scripts/check_routing_issue.py` | Диагностика маршрутизации. |
| `scripts/check_server_protocols.py` | Проверка протоколов серверов. |
| `scripts/check_servers_simple.py` | Простая проверка серверов через SQL. |
| `scripts/check_servers_status.py` | Статус серверов и протоколов. |
| `scripts/check_user_connection_status.py` | Статус подключения пользователя. |
| `scripts/check_user_token.py` | Проверка пользователя и выдача токена. |
| `scripts/check_xray_logs.py` | Анализ логов Xray. |
| `scripts/check_xray_status.py` | Статус Xray на сервере. |
| `scripts/clear_servers_cache.py` | Очистка кэша серверов. |
| `scripts/create_owner.py` | Создание Owner-пользователя. |
| `scripts/create_owner_auto.py` | Автосоздание Owner. |
| `scripts/create_tables.py` | Создание таблиц БД. |
| `scripts/create_trial_subscription.py` | Триал/подписка для пользователя. |
| `scripts/debug_traffic.py` | Диагностика трафика. |
| `scripts/debug_xray_client_creation.py` | Отладка создания Xray-клиента. |
| `scripts/dedupe_device_ids.py` | Дедупликация `device_id`. |
| `scripts/deploy_api_proxy_hungary.py` | Деплой nginx+certbot на HU-BUD-01. |
| `scripts/diagnose_port_4443.py` | Диагностика порта 4443. |
| `scripts/diagnose_wireguard_server.py` | Диагностика WireGuard на сервере. |
| `scripts/diagnose_xray_connection.py` | Диагностика подключения Xray (email/device_id). |
| `scripts/enable_all_protocols.py` | Включение всех протоколов на серверах (тесты). |
| `scripts/export_client_configs.py` | Экспорт конфигов клиентов. |
| `scripts/fetch_server_logs.py` | Логи с VPN-сервера через RemoteVPNManager. |
| `scripts/fix_accept_proxy_4443.py` | acceptProxyProtocol для VLESS 4443. |
| `scripts/fix_reality_server_configs.py` | Синхронизация REALITY на серверах. |
| `scripts/fix_routing.py` | Исправление маршрутизации WG. |
| `scripts/fix_traffic_routing.py` | Детальная правка маршрутизации. |
| `scripts/fix_wireguard_config.py` | Правка WG (в т.ч. DNS/resolvconf). |
| `scripts/fix_xray_config_path.py` | Путь конфига Xray. |
| `scripts/fix_xray_connection_issues.py` | Исправление проблем Xray. |
| `scripts/fix_xray_duplicates.py` | Дубликаты пользователей в конфиге Xray. |
| `scripts/fix_xray_port.py` | Порт Xray (443→4443 и т.д.). |
| `scripts/fix_xray_service.py` | Диагностика/починка сервиса Xray. |
| `scripts/force_disconnect_and_connect_xray.py` | Принудительный reconnect Xray. |
| `scripts/hungary_api_and_reality_rollout.py` | Rollout api+REALITY на HU-BUD-01. |
| `scripts/migrate_hungary_reality_port_to_2053.py` | Одноразово: REALITY порт 2053 в БД. |
| `scripts/normalize_user_devices.py` | Нормализация устройств пользователя. |
| `scripts/ops/edge_alerts_check.py` | Алерты edge-agent (heartbeat, assignments), опционально Telegram. |
| `scripts/patch_hungary_xray_reality_port.py` | SSH: перенос REALITY 443→2053 на HU. |
| `scripts/quick_test_xray.py` | Быстрый тест Xray. |
| `scripts/rotate_secrets.py` | Ротация секретов без остановки сервиса. |
| `scripts/script_env.py` | Загрузка `.env` до импорта `core.*`. |
| `scripts/seed_protocols.py` | Сид таблицы `protocols`. |
| `scripts/server_diagnostic_quick.py` | Быстрая диагностика HU-BUD-01. |
| `scripts/set_xray_defaults.py` | Дефолты Xray-полей в БД. |
| `scripts/setup_hungary_server.py` | Полная настройка венгерского сервера. |
| `scripts/setup_server_protocols.py` | Настройка протоколов на серверах. |
| `scripts/setup_vpn_server.py` | Настройка VPN-сервера по SSH. |
| `scripts/setup_xray_cron_watchdog.py` | Cron watchdog Xray на ноде. |
| `scripts/setup_xray_for_clients.py` | Xray под клиентов. |
| `scripts/setup_xray_server.py` | Установка/настройка Xray на VPN-сервере. |
| `scripts/setup_xray_stats_api.py` | Xray Stats API. |
| `scripts/sni_block_simulator_addon.py` | mitmproxy addon: симуляция DPI/SNI. |
| `scripts/sync_server_protocols.py` | Синхронизация `supported_protocols`. |
| `scripts/test_all_protocols.py` | Тест Xray-протоколов через API. |
| `scripts/test_registration_flow.py` | E2E регистрация + токен. |
| `scripts/test_servers_api.py` | Тест `GET /vpn/servers`. |
| `scripts/test_ssh_connection.py` | Тест SSH к VPN-серверу. |
| `scripts/test_token_servers.py` | Токен → список серверов. |
| `scripts/test_vpn_fixes.py` | Регрессия фиксов VPN. |
| `scripts/test_xray_client_creation.py` | Создание Xray-клиента. |
| `scripts/test_xray_setup.py` | Проверка настроек Xray. |
| `scripts/test_xray_stats.py` | Статистика Xray. |
| `scripts/update_server_xray_port.py` | Обновление порта Xray в БД. |
| `scripts/update_wg_config_rules.py` | Правила iptables WG. |
| `scripts/verify_server_setup.py` | Финальная проверка сервера. |
| `scripts/verify_vpn_deploy.py` | Проверка после деплоя API. |
| `scripts/vpn_tester.py` | Интерактивный тестер VPN. |

*Автоматический разбор docstring пометил 3 файла как «syntax error» при `ast.parse` из‑за размера/фрагмента; строки для `check_and_fix_server`, `diagnose_xray_connection`, `ops/edge_alerts_check` восстановлены вручную из заголовков файлов.*

---

## 3. Фокус: почему «показатели не устраивают» (связь с кодом)

| Наблюдение | Где копать |
|------------|------------|
| Долгий первый connect | `session/prepare` → SSH + `create_xray_client`; кэш Redis; блокировка `asyncio.Lock` в `api/vpn.py`. |
| Нагрузка на API при стабильной сети | Nginx `limit_req`, пул Gunicorn, время запросов в логах Nginx (`rt=`). |
| Очереди / лаг фона | Celery: длина очередей Redis, время `vpn.apply_xray_config` vs beat **каждые 30 с** `update_server_load`. |
| Рост Redis / память | `maxmemory` + политика; большие pickle в кэше (`session_prepare`, `xray_config:server:*`). |
| Рассинхрон устройств | `Device.is_active`, кэш `cache:devices:*`, инвалидация в `invalidate_user_cache`. |

---

## 4. Следующие шаги (рекомендации)

1. **Метрики:** Prometheus или хотя бы периодический сбор: длина очередей Celery, `redis INFO`, p95 `request_time` Nginx, `slow_query` из логов SQLAlchemy.
2. **Разделение нагрузки:** отдельный воркер только для `monitoring` vs `vpn`, если общая `concurrency` мала.
3. **Профилирование:** один замер `session_prepare` с разбивкой SSH / JSON / DB (логи уже содержат `elapsed_ms` и `cache=`).

---

*Файл можно версионировать в репозитории и дополнять результатами профилирования.*

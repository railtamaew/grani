# Подключение к HU-BUD-01 (45.12.132.94)

## Где хранится доступ

Доступ хранится в БД в таблице `servers` для записи **HU-BUD-01** (IP 45.12.132.94).

Обязательные поля:

| Поле           | Значение          |
|----------------|-------------------|
| ssh_host       | 45.12.132.94      |
| ssh_port       | 22                |
| ssh_user       | root              |
| ssh_key_content| заполнен (PEM)    |
| ssh_password   | NULL              |
| ssh_key_path   | NULL              |

## Как это используется

Операции через SSH проходят через `RemoteVPNManager.get_ssh_config()` — параметры берутся из `servers`, используется ключ (пароль игнорируется при наличии ключа).

Источник: `backend/services/remote_vpn_manager.py` (метод `get_ssh_config`).

## Как агенту запускать

Запускать через скрипты, использующие RemoteVPNManager:

```bash
# Развёртывание nginx reverse proxy + certbot для api.granilink.com
PYTHONPATH=/opt/grani/backend python3 /opt/grani/backend/scripts/deploy_api_proxy_hungary.py
```

Другие скрипты:

```bash
# Полная настройка сервера (WireGuard + Xray)
PYTHONPATH=/opt/grani/backend python3 /opt/grani/backend/scripts/setup_hungary_server.py

# Проверка Xray на HU-BUD
PYTHONPATH=/opt/grani/backend python3 /opt/grani/backend/scripts/check_hungary_xray.py
```

## Порты на HU-BUD-01 (45.12.132.94)

| Порт | Назначение |
|------|------------|
| **443** | HTTPS nginx — reverse proxy к API (api.granilink.com → DigitalOcean) |
| **2053** | XRay REALITY (раньше 443; освобождён под API) |
| **4443** | XRay VLESS |
| **8443** | XRay VMESS |
| **8444** | HTTPS nginx — тот же API-прокси, что 443 (запасной порт; 8443 не использовать под API) |
| **51820** | WireGuard |

Константа в коде: `XRAY_REALITY_DEFAULT_PORT = 2053` (`backend/core/constants.py`).  
Миграция БД: `backend/scripts/migrate_hungary_reality_port_to_2053.py`.  
На самой ноде inbound REALITY нужно перенести с 443 на 2053 и перезагрузить Xray.

## Важно

- Пароля нет и он не нужен
- В production используется только ключ из `ssh_key_content`
- **Скрипты должны запускаться в окружении с доступом к БД**: нужны корректные `DATABASE_URL` и `.env` backend (production/staging, где backend подключается к БД)

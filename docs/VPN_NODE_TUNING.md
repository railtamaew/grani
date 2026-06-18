# Настройка VPN-нод (Xray)

Рекомендации по лимитам и ядру для стабильной работы Xray при большом числе соединений.

## 1. LimitNOFILE для systemd (Xray)

При большом количестве клиентов процесс Xray может упираться в лимит открытых файлов (дескрипторов). Рекомендуется повысить лимит в unit-файле.

**Создание override (один раз на ноде):**

```bash
sudo mkdir -p /etc/systemd/system/xray.service.d
sudo tee /etc/systemd/system/xray.service.d/override.conf << 'EOF'
[Service]
LimitNOFILE=65536
EOF
sudo systemctl daemon-reload
sudo systemctl restart xray
```

Проверка после перезапуска:

```bash
cat /proc/$(pgrep -f xray)/limits | grep "open files"
# Ожидается: 65536
```

## 2. TCP-буферы ядра (опционально)

При очень высокой нагрузке можно увеличить TCP-буферы. Добавьте в `/etc/sysctl.d/99-vpn-node.conf`:

```ini
# Увеличение диапазона локальных портов
net.ipv4.ip_local_port_range = 1024 65535
# Буферы приёма/передачи (опционально, по необходимости)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
```

Применить: `sudo sysctl -p /etc/sysctl.d/99-vpn-node.conf`

## 3. Связь с бэкендом

- Прогрев кэша конфигов Xray при старте API уменьшает задержку первого create-client (см. `main.py` → `startup_warm_xray_cache`).
- При нескольких воркерах API обязательно задать `CACHE_BACKEND=redis` и `RATE_LIMIT_STORE=redis` (см. `backend/docs/DEPLOYMENT.md`).
- При синхронном применении конфига (без Celery) бэкенд использует один SSH-сеанс на запись конфига и reload (`apply_config_to_server` / `_update_xray_config_and_reload` в `services/xray_manager.py`).

## 4. ExecReload для `systemctl reload xray`

Если в unit-файле Xray не задан корректный `ExecReload`, `systemctl reload xray` завершается с ошибкой и бэкенд вынужден делать **`restart`**, что рвёт активные inbound-сессии. На ноде задайте drop-in (шаблон в репозитории: `server-config/systemd/xray.service.d/grani-exec-reload.conf.example`): проверка конфига и **SIGHUP** процессу Xray вместо полного stop/start.

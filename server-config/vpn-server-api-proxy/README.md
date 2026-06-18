# API reverse proxy на VPN-сервере (45.12.132.94)

Проксирует **api.granilink.com** и **api.granilink.com** (вариант A: Cloudflare → эта нода) на основной API (159.223.199.122).

На этой же ноде **XRay REALITY слушает порт 2053**, а не 443 — чтобы **443** был свободен для nginx (см. `XRAY_REALITY_DEFAULT_PORT` в `backend/core/constants.py`).

## Предварительные условия

1. DNS: A-запись `api.granilink.com` → `45.12.132.94` (см. docs/DNS_GRANILINK_SETUP.md)
2. Nginx установлен на VPN-сервере
3. Порты **80**, **443** и **8444** открыты (**8444** — тот же API-прокси; **8443** = VMESS)
4. XRay REALITY на **2053**, не на 443 (иначе конфликт с nginx)

## Полный rollout (БД + Xray + nginx)

Один заход, если есть доступ к production PostgreSQL и SSH-ключ сервера в БД:

```bash
cd /opt/grani
python3 backend/scripts/hungary_api_and_reality_rollout.py
```

Переменные БД читаются из `backend/.env` (или `GRANI_BACKEND_ENV_FILE`).

Скрипт по порядку: миграция `servers.xray_port` → патч `config.json` Xray (443→2053) → деплой nginx/certbot.

## Установка

### Через backend (ключ из БД, рекомендуемый способ)

Использует `RemoteVPNManager` — SSH-ключ из `servers.ssh_key_content` для HU-BUD-01.

```bash
cd /opt/grani
python3 backend/scripts/deploy_api_proxy_hungary.py
```

См. `docs/HU_BUD_01_SSH_ACCESS.md` — инструкция по доступу к HU-BUD-01 через БД.

### Через локальный SSH-ключ

```bash
cd server-config/vpn-server-api-proxy
chmod +x deploy-via-ssh.sh

SSH_KEY=~/.ssh/id_rsa SSH_USER=root ./deploy-via-ssh.sh
```

### Вручную на сервере

```bash
# На VPN-сервере 45.12.132.94
sudo cp api-proxy-http-only.conf /etc/nginx/conf.d/api-proxy.conf
sudo nginx -t && sudo systemctl reload nginx

sudo certbot certonly --nginx -d api.granilink.com

sudo cp api-proxy.conf /etc/nginx/conf.d/
sudo nginx -t && sudo systemctl reload nginx
```

## Проверка

```bash
curl -s https://api.granilink.com/api/vpn/bootstrap
curl -s https://api.granilink.com:8444/api/vpn/bootstrap
curl -s https://api.granilink.com/health
```

Полный чек второго шага (443 + 8443, в т.ч. через IP):

```bash
./server-config/vpn-server-api-proxy/check-step2.sh
```

Результаты и действия при ошибках: `docs/API_VARIANT_A_FIRST_STEPS.md` (раздел «Проверки второго шага»).

## IP fallback

Клиент может подключаться к `https://45.12.132.94` с заголовком `Host: api.granilink.com` — тот же server block обработает запрос (45.12.132.94 в server_name).

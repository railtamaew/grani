# Настройка DNS granilink.com для API (Reg.ru)

## Текущие записи — НЕ ТРОГАТЬ

Сохраняются без изменений (Yandex Postbox и проверки):

| Тип  | Хост              | Значение                    |
|------|-------------------|-----------------------------|
| MX   | @                 | mx.yandex.net. (приоритет 10) |
| TXT  | @                 | SPF: `v=spf1 ip4:159.223.199.122 ... include:_spf.yandex.net ~all` |
| TXT  | @                 | google-site-verification=... |
| TXT  | @                 | yandex-verification: f9e66cd0ae857ead |
| CNAME| mail._domainkey   | (DKIM для Yandex)           |
| CNAME| support._domainkey| (DKIM для Yandex)           |
| A    | @                 | 176.57.66.222               |
| A    | www               | 176.57.66.222               |

## Добавить

### A-запись для API

| Тип | Хост | Значение        | TTL  |
|-----|------|-----------------|------|
| A   | api  | 45.12.132.94    | 3600 |

Это создаст `api.granilink.com` → IP VPN-сервера. На VPN-сервере будет reverse proxy к основному API.

## Порядок действий

1. В панели Reg.ru откройте DNS для granilink.com.
2. Добавьте запись:
   - Тип: **A**
   - Имя/хост: **api** (поддомен api.granilink.com)
   - Значение/IP: **45.12.132.94**
3. Сохраните изменения.
4. Не изменяйте и не удаляйте MX, TXT, CNAME для mail._domainkey и support._domainkey.

## Проверка

```bash
dig api.granilink.com +short
# Ожидается: 45.12.132.94
```

## Firewall

На ноде и у провайдера должны быть открыты **80/tcp**, **443/tcp** и **8444/tcp** (запасной HTTPS nginx→API; **8443** занят Xray VMESS, см. `server-config/vpn-server-api-proxy/api-proxy.conf`).

## После DNS — на сервере HU-BUD-01

1. **REALITY не на 443** — inbound VLESS+REALITY должен слушать **2053**, чтобы **443** был для nginx. Из машины с доступом к production БД и ключом в `servers.ssh_key_content`:
   - полный цикл (из корня репо; подхватывается `backend/.env`): `python3 backend/scripts/hungary_api_and_reality_rollout.py`
   - или по шагам: те же скрипты по отдельности. Другой путь к `.env`: `GRANI_BACKEND_ENV_FILE=/path/.env`
2. **SSL и nginx** — см. `server-config/vpn-server-api-proxy/README.md` (certbot + `api-proxy.conf`).

## SSL

После обновления DNS на VPN-сервере (45.12.132.94) нужно выпустить сертификат Let's Encrypt для api.granilink.com; проще всего через `deploy_api_proxy_hungary.py` или вручную по README в `server-config/vpn-server-api-proxy/`.

Прокси и SSL в Cloudflare без переноса зоны `granilink.com`: **вариант A** — `docs/API_VARIANT_A_FIRST_STEPS.md`; обзор — `docs/CLOUDFLARE_API_SETUP.md`.

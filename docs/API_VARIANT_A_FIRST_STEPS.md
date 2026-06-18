# Вариант A: Reg.ru + Cloudflare (API отдельным доменом)

Цель: не переносить зону `granilink.com` в Cloudflare; трафик **api.granilink.com** идёт в **Cloudflare → 45.12.132.94 (HU-BUD)** → тот же nginx → основной API на DO.

См. также: `docs/DNS_GRANILINK_SETUP.md`, `docs/CLOUDFLARE_API_SETUP.md`, `server-config/vpn-server-api-proxy/README.md`.

## 1. Проверки второго шага (порт 8444)

Порт **8443** на ноде — Xray VMESS; запасной HTTPS API — **8444**.

```bash
./server-config/vpn-server-api-proxy/check-step2.sh
```

## 2. Reg.ru (`granilink.com`)

Не переносить NS в CF. A **api** → **45.12.132.94** для `api.granilink.com` (см. `docs/DNS_GRANILINK_SETUP.md`). MX/SPF/DKIM не трогать.

## 3. Cloudflare (зона **granilink.com**)

1. Добавить сайт **granilink.com** в Cloudflare, сменить NS у регистратора домена на выданные CF.
2. **DNS → A**: имя **api**, IPv4 **45.12.132.94**, **Proxied** (оранжевое облако).
3. **SSL/TLS → Overview**: **Full (strict)** после того, на origin в nginx есть валидный сертификат на **api.granilink.com** (Let's Encrypt на HU-BUD, SAN вместе с api.granilink.com — см. `deploy_api_proxy_hungary.py`). До этого — временно **Full** только для отладки.
4. **Кэш API не кэшировать:**
   - **Caching → Cache Rules → Create rule:** если *URI Path* **starts with** `/api`, то **Cache eligibility: Bypass cache** (или аналог в вашей версии UI).
   - Либо **Page Rule** (legacy): URL `*api.granilink.com/api*` → Cache Level: Bypass.
5. Не включать жёсткий WAF/challenge на все запросы без проверки мобильного клиента.

## 4. Nginx + сертификат на HU-BUD-01

В репозитории `server_name` уже включает **api.granilink.com** на 80/443/8444. Выкат:

```bash
cd /opt/grani && PYTHONPATH=backend python3 backend/scripts/deploy_api_proxy_hungary.py
```

Скрипт пытается выпустить/расширить LE на **api.granilink.com** и **api.granilink.com**. Если **api.granilink.com** ещё не указывает на ноду, остаётся сертификат только на granilink — после настройки DNS в CF запустите скрипт снова.

**HTTP-01 и Cloudflare:** если оранжевое облако мешает выдаче сертификата, временно выключите прокси (DNS only) для **api** на время certbot или используйте DNS-challenge certbot.

Проверка:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://api.granilink.com/api/vpn/bootstrap
curl -sS -o /dev/null -w '%{http_code}\n' https://api.granilink.com:8444/api/vpn/bootstrap
```

## 5. Backend и приложение

- `backend/api/bootstrap.py` добавляет `https://api.granilink.com/api` и `:8444` в `api_base_urls`.
- Мобильное приложение: `AppConfig.apiGranivpnRuViaHuUrl` и список `apiBaseUrls`.

После деплоя кода API на сервере с Docker: **`docker compose restart api`** (volume `backend:/app` — воркеры подхватывают код после рестарта).

## 6. Сертификаты (кратко)

| Имя | Где |
|-----|-----|
| api.granilink.com (+ SAN api.granilink.com) | LE на HU-BUD, путь обычно `/etc/letsencrypt/live/api.granilink.com/` |
| Прямой api.granilink.com на DO | Без изменений; клиенты через CF приходят на HU по A-записи |

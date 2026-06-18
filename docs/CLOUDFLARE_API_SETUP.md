# Cloudflare перед API (granilink / отдельный поддомен)

**Вариант A (granilink.com в CF, api → HU-BUD):** пошагово — **`docs/API_VARIANT_A_FIRST_STEPS.md`** (DNS, SSL Full strict, **Bypass cache** для `/api`, certbot SAN на ноде, bootstrap и мобильное приложение). Скрипт проверки 443/8444: `server-config/vpn-server-api-proxy/check-step2.sh`.

Кратко: **почта на корне `granilink.com` (MX, SPF, DKIM) не должна зависеть от настроек API-поддомена**, но при **переносе всей зоны** в Cloudflare нужно **скопировать все существующие записи** из Reg.ru (включая MX и TXT), иначе почта сломается.

## Зачем Cloudflare

- WAF, rate limiting, скрытие origin-IP (если клиенты ходят только на имя за прокси).
- Запасной HTTPS на ноде — порт **8444** (не 8443: там VMESS): см. `api-proxy.conf`; при блокировке 443 — `https://45.12.132.94:8444/api` или домен с `:8444`.

## Вариант A — только API за Cloudflare, DNS зоны остаётся на Reg.ru

Практичный путь без переноса NS:

1. Оставьте зону `granilink.com` на Reg.ru как сейчас (см. `docs/DNS_GRANILINK_SETUP.md` — **не трогать** MX/SPF/DKIM).
2. Для API используйте **отдельное имя**, зону которого ведёте в Cloudflare, например поддомен на другом домене проекта (`api.granilink.com`) или новую зону только под технические имена.
3. В Cloudflare: **DNS → A** (или CNAME на туннель) на origin **45.12.132.94** (или на IP, который вы реально используете как origin).
4. Включите **прокси** (оранжевое облако) для этой записи API, если трафик должен идти через Cloudflare.

Так вы **не рискуете** случайно сменить MX у `granilink.com`.

## Вариант B — вся зона `granilink.com` в Cloudflare

Делайте только если готовы **импортировать полный набор записей**:

1. Cloudflare → **Add site** → `granilink.com`.
2. Импортируйте записи с Reg.ru **один в один**: A, MX, TXT (SPF, верификации), CNAME для DKIM (`mail._domainkey`, `support._domainkey` и т.д.).
3. Проверьте, что **MX** указывает на Yandex (или ваш текущий провайдер почты) и **TXT SPF** совпадает с боевым.
4. Смените **NS** у регистратора на те, что выдал Cloudflare, только после проверки превью зоны.
5. Запись **api**: тип **A**, имя `api`, значение **45.12.132.94**, прокси по необходимости.

**Корень `@` и `www`** не обязаны быть за прокси; для API достаточно оранжевого облака на `api`.

## SSL/TLS к origin

- Режим **Full (strict)**: на origin (HU-BUD-01) должен быть **валидный** сертификат на то имя, с которым клиент/Cloudflare подключается к nginx (например **Let's Encrypt** для `api.granilink.com` — как в `deploy_api_proxy_hungary.py`).
- Если origin только по IP без имени в сертификате — **Full strict** к IP не подойдёт; используйте имя в SNI/Host (`api.granilink.com`).

## Что не включать слепо

- **Always Use HTTPS** / редиректы — обычно ок для API на 443.
- Агрессивный **WAF** или challenge ко всем путям — может ломать мобильный клиент; для `/api/*` лучше правила «allow» или мягкий уровень.
- **Cache** для динамического API — отключите (или Bypass cache для `/api`).

## Проверка после изменений

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://api.granilink.com/api/vpn/bootstrap
curl -sS -o /dev/null -w '%{http_code}\n' https://api.granilink.com:8444/api/vpn/bootstrap
```

Связанные файлы: `server-config/vpn-server-api-proxy/README.md`, `docs/DNS_GRANILINK_SETUP.md`, ответ bootstrap в `backend/api/bootstrap.py`.

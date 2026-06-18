# API диагностика (2026-03-19)

Выполнено по плану [api_stability_tech_audit](.cursor/plans/api_stability_tech_audit_4094d01f.plan.md).

## Шаг 1. Проверка API снаружи

```bash
curl -w "time_connect=%{time_connect}s time_starttransfer=%{time_starttransfer}s time_total=%{time_total}s" -o /dev/null -s https://api.granilink.com/health
```

**Результат:** time_connect=0.09s, time_starttransfer=0.18s, time_total=0.18s

**Интерпретация:** В норме. Nginx возвращает статический 200 "healthy" без проксирования на backend.

---

## Шаг 2. Стабильность API (5 запросов bootstrap)

```bash
for i in {1..5}; do curl -s -o /dev/null -w "%{http_code} %{time_total}\n" https://api.granilink.com/api/vpn/bootstrap; done
```

**Результат:** 200 ~0.09s на запрос (все успешны)

---

## Шаг 3. Логи backend

Требует доступ к серверу:
```bash
docker logs --tail 500 granivpn_api 2>&1 | grep -E "send-code|verify-code|devices|create-client|xray"
```

Искать: `[send-code-timing]`, `[verify-code-timing]`, долгие запросы (>1 с), ошибки.

---

## Шаг 4. Нагрузка сервера

```bash
top -bn1; free -h; uptime
```

CPU > 80%, load average > ядер, OOM → перегруз.

---

## Шаг 5. Сеть и latency

```bash
ping -c 5 api.granilink.com
```

**Результат:** 0% packet loss, rtt min/avg/max/mdev = 0.053/0.064/0.080/0.010 ms

---

## Шаг 6. TLS handshake

```bash
openssl s_client -connect api.granilink.com:443 -servername api.granilink.com </dev/null
```

**Результат:** CONNECTED, Let's Encrypt R13 сертификат для api.granilink.com

---

## Шаги 7–9

- **Шаг 7 (Auth):** Проверить логи `[send-code-timing]`, `[verify-code-timing]`
- **Шаг 8 (devices):** Кеш 60 с (`cache:devices:{user_id}`), cold cache → PostgreSQL
- **Шаг 9 (VPN):** Использовать [vpn-diagnostics](../.cursor/rules/vpn-diagnostics.mdc) — SSH на VPN-сервер, логи Xray

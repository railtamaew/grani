# Повторный анализ проблемы VPN-соединения (по правилу vpn-diagnostics)

**Источник:** `/opt/grani/.cursor/rules/vpn-diagnostics.mdc`  
**Исходные данные:** логи OnePlus, анализ `VPN_AUTH_TIMEOUT_ANALYSIS_2026-02-20.md`, код бэкенда и мобильного приложения.

---

## Контекст

На устройстве наблюдался **connection timeout (10 с)** при обращении к API (`api.granilink.com`, затем fallback на `159.223.199.122`) **до установления VPN-туннеля**: после успешного Google OAuth запросы к `/api/auth/google/callback` и bootstrap не проходят. Таким образом, проблема — **доступность API с устройства**, а не работа самого Xray/WireGuard после подключения.

Ниже — разбор по чек-листу диагностики VPN-соединения.

---

## 1. Серверная сторона (VPN-сервер Xray)

| Проверка | Как выполнить | Текущий вывод |
|----------|----------------|---------------|
| SSH к VPN-серверу | Из контейнера `granivpn_api`: ключ из БД `servers.ssh_key_content` (Ed25519), хост — `server.ip_address` / `server.ssh_host` | Код: `RemoteVPNManager.get_ssh_config(server)` использует `ssh_key_content` или `ssh_key_path`. SSH с текущей машины к 159.223.199.122 недоступен (publickey). |
| Статус Xray | `systemctl is-active xray`, `xray version`, `ss -tlnp \| grep -E "443\|4443\|8443"` | Не проверялось на проде (нет доступа по SSH из окружения). |
| Конфиг Xray | `/usr/local/etc/xray/config.json` (или `server.xray_config_path`) — inbounds, порты, security, clients | Читается через `RemoteVPNManager.get_xray_config(server)` по SSH. В коде дефолт: `/usr/local/etc/xray/config.json`. |
| Логи Xray | `/var/log/xray/access.log`, `/var/log/xray/error.log` — искать email клиента, accepted/rejected | Получение через API: `GET /api/vpn/servers/{id}/logs?protocol=xray&log_type=access|error&lines=100`. В текущем инциденте **VPN-трафик не устанавливался** — запросы к API не доходили до nginx, до Xray запросы с устройства не доходят. |
| Firewall | `iptables -L INPUT -n`, при необходимости ufw | В анализе от 20.02 рекомендовано проверить на сервере; блокировка по IP возможна, но тогда бы другие клиенты тоже не проходили — по access.log другие IP получают 200. |

**Вывод по п.1:** Для инцидента с OnePlus проблема не на VPN-сервере Xray: трафик до сервера не доходит на этапе **HTTP(S) к API**. Проверки по правилу (xray, конфиг, access/error.log) имеют смысл при уже установленном туннеле или при отдельной диагностике «не поднимается VPN».

---

## 2. Бэкенд (API-сервер)

| Проверка | Как выполнить | Текущий вывод |
|----------|----------------|---------------|
| Логи API | `docker logs --tail 200 granivpn_api` | В интервале 12:48–12:53 UTC запросов от устройства не было; другие IP получают 200. Логи приложения не показывают ошибок по нашему устройству. |
| БД: серверы | Таблица `servers`: IP, порты, reality_enabled, ssh_key | Код использует `server.ip_address`, `xray_port`, `xray_config_path`, `ssh_key_content` и т.д. Для проверки нужен доступ к БД на проде. |
| БД: устройства | `devices`: protocol, vpn_client_id, is_active | Нужен доступ к БД. При таймауте до API устройство может не быть создано/обновлено. |
| Генерация json_config | Порт, tls, протокол — соответствие серверному inbound | Актуально для сценария «VPN подключается, но не работает». В нашем случае конфиг до клиента не доходит из‑за таймаута к API. |
| Нагрузка | CPU/RAM | По предыдущему анализу: CPU 0.89%, RAM 226 MB / 7.7 GB — бэкенд не перегружен. |

**Вывод по п.2:** Бэкенд и nginx в момент инцидента работали; в nginx access.log **нет записей от IP устройства** в окне 12:48–12:53 UTC. Значит, отказ происходит до входа запроса в nginx (клиент/сеть).

---

## 3. Клиентская сторона

| Проверка | Источник данных | Текущий вывод |
|----------|-----------------|---------------|
| Адрес/порт подключения к API | Логи приложения (ConnectionLogger, auth_service) | Подключение к `https://api.granilink.com` и к `159.223.199.122` (fallback). connectTimeout 10 с. |
| Routing (direct/proxy) | Логи, конфиг туннеля | Запросы к API выполняются **до** включения VPN; routing loop маловероятен. |
| Ошибки tun2socks | Логи клиента (Android: XrayNativeWrapperTun2Socks, Tun2SocksProcessService) | В описанном сценарии VPN не поднимается из‑за отсутствия bootstrap/токена; ошибки tun2socks (в т.ч. `BSocksClient_Init failed`) не фигурируют в отчёте. |
| Соответствие порт/security клиента и сервера | Конфиг приложения vs inbound на сервере | Не применимо: конфиг до клиента не доставлен из‑за таймаута к API. |
| Routing loop | В логах: `proxy/socks: TCP Connect request to VPN_SERVER_IP` | Нет данных; при таймауте до API туннель не активен. |
| `BSocksClient_Init failed` | Логи tun2socks / Xray на устройстве | В текущем инциденте не отмечено. |

**Вывод по п.3:** Проблема на клиенте — **не установление TCP/TLS до api.granilink.com и до IP** в течение 10 с. Реализация: `createIpv4PreferredHttpClient()` (IPv4-only + ручной TLS в connectionFactory) добавлена для устранения IPv6-задержек; при сохранении таймаутов причина, по правилу, может быть сеть/DNS или split tunnel (в данном случае VPN выключен).

---

## 4. Перекрёстная проверка

| Проверка | Результат |
|----------|-----------|
| Email клиента (формат `userId_deviceId@granivpn.com`) в access.log Xray | Не применимо: VPN-сессия не устанавливается, трафик до Xray не идёт. |
| 0 записей в nginx access.log от IP устройства | **Подтверждено:** в 12:48–12:53 UTC запросов от устройства нет → трафик **не доходит до сервера**. |
| error.log nginx по IP клиента | Записей по нашему IP не было (соединение не устанавливается). |
| REALITY в error.log Xray | Не применимо — запросы до VPN-сервера не доходят. |
| Таймзоны | Клиент (логи 15:48 MSK), сервер (12:48 UTC) — согласованы. |

**Вывод по п.4:** Критичный факт — **отсутствие записей от IP устройства в nginx access.log** в момент ошибки. Это однозначно указывает на проблему до сервера (сеть, маршрутизация, блокировка, IPv6/TLS на клиенте).

---

## 5. Соответствие частым проблемам (из правила)

| Симптом | Причина | Наш случай |
|---------|---------|------------|
| `REALITY: failed to read client hello` | Клиент шлёт plain VLESS на REALITY-порт (443 vs 4443) | Нет: до Xray трафик не доходит. |
| `BSocksClient_Init failed` | Xray SOCKS proxy упал или перегружен | Нет в отчёте. |
| `splice: connection reset by peer` на localhost | Routing loop или protect() failure | Нет в отчёте. |
| 0 записей email в access.log (Xray) | Трафик не доходит до VPN-сервера | По API: 0 записей в **nginx** access.log от IP устройства — та же природа: трафик не доходит. |
| **`DioException [connection timeout]` к API** | Сеть/DNS при включённом VPN, проверить split tunnel | **Совпадает.** В нашем случае VPN ещё не включён; причина — недоступность API с устройства (сеть/DNS/IPv6/firewall). |

---

## Порты (из правила и constants)

| Порт | Протокол / безопасность | Константа в коде |
|------|-------------------------|-------------------|
| **443** | VLESS + REALITY (TLS-обфускация) | `XRAY_DEFAULT_PORT` |
| **4443** | VLESS + none (plain) | `XRAY_VLESS_DEFAULT_PORT` |
| **8443** | VMess + none | `XRAY_VMESS_DEFAULT_PORT` |

API (nginx) — 443 (HTTPS), внутри Docker API на 8010→8000.

---

## Root cause (итог)

**Установленная причина:** запросы с устройства OnePlus к `api.granilink.com` и к `159.223.199.122` **не доходят до nginx** (в access.log нет записей от IP устройства в момент сбоя). Таймаут соединения возникает на стороне клиента до установления TCP/TLS.

**Вероятные причины (по приоритету):**

1. **Сеть оператора / маршрутизация** — блокировка или нестандартный путь до api.granilink.com и до IP.
2. **IPv6** — приоритет IPv6 при резолве, нерабочий IPv6-путь, долгий fallback на IPv4 (в приложении внедрён IPv4-only клиент).
3. **Firewall на сервере** — блокировка по IP/подсети (рекомендовано проверить `iptables`, ufw).
4. **TLS** — маловероятно при «0 записей в access.log»; при TLS-ошибках обычно есть запись в error.log.

---

## Решения

### Немедленные (ручные проверки)

1. **С устройства:** в браузере открыть `https://api.granilink.com/api/vpn/bootstrap` — при успехе проблема может быть в приложении (таймаут/DNS); при таймауте — сетевая.
2. **Другая сеть:** Wi‑Fi, другой оператор, мобильный интернет.
3. **На сервере:** `sudo iptables -L -n`, `sudo ufw status` — нет ли блокировки по IP устройства.
4. **Логи бэкенда:** выполнить `./server-config/check-backend-logs.sh` с машины с SSH-доступом к 159.223.199.122 — сверить access/error nginx и логи API за время повторения проблемы.

### В коде (уже сделано / можно усилить)

1. **IPv4-only HTTP-клиент** — `createIpv4PreferredHttpClient()` в ApiClient, AuthService, ConnectionLogger (избежание длительного IPv6 timeout).
2. **Ручной TLS в connectionFactory** — корректный HTTPS при подключении по IP (SNI, onBadCertificate).
3. **Опционально:** увеличение `connectTimeout` до 15–20 с для медленных сетей.
4. **Диагностика VPN-туннеля (когда он уже есть):** по правилу — получение логов Xray через API `GET /api/vpn/servers/{id}/logs`, проверка email в access.log Xray, сравнение порта/security с серверным inbound.

---

## Как использовать этот отчёт

- При **повторном таймауте к API** — ориентироваться на разделы 2 (бэкенд/nginx), 3 (клиент), 4 (перекрёстная проверка) и блок «Решения».
- При **проблеме «VPN подключается, но не работает»** — выполнять полный чек-лист п.1 (VPN-сервер Xray), п.2 (БД, json_config), п.3 (tun2socks, порт/security), п.4 (email в access.log Xray, error.log REALITY).

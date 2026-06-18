# Технический аудит: причины тормозов и конфликтов

**Дата:** 2026-03-17  
**Контекст:** «100 тысяч сайтов работают, а наш тормозит» — сервис должен работать в строжайших условиях.

---

## 1. Критические проблемы

### 1.1 ConnectionLogger — без URL fallback

**Файл:** `lib/services/connection_logger.dart`

- Использует **только** `AppConfig.apiBaseUrl` (api.granilink.com), **без перебора** `AppConfig.apiBaseUrls`.
- При блокировке домена оператором логи **не отправляются** никогда.
- `createIpv4PreferredHttpClient()` **без** `badCertificateCallback` и `sniHostWhenConnectingByIp` — при подключении по IP (если бы добавили fallback) SSL бы падал.
- **Рекомендация:** Добавить перебор URL по `AppConfig.apiBaseUrls`, Host header и bad cert для IP.

### 1.2 DNS lookup — до 5 секунд на каждый запрос

**Файл:** `lib/core/api/ipv4_http_client.dart` (стр. 24–28)

```dart
final addresses = await InternetAddress.lookup(
  connectHost,
  type: InternetAddressType.IPv4,
).timeout(const Duration(seconds: 5));
```

- При медленном/блокируемом DNS каждый запрос ждёт **до 5 с** на резолв.
- Порядок URL: сначала домен, потом fallbacks, потом IP. При медленном DNS: 5s + 5s + 5s = **до 15 с** до первого успешного запроса.
- **Рекомендация:** Сократить timeout до 2–3 с; рассмотреть параллельный запрос (domain + IP) или приоритет IP при повторных сбоях DNS.

### 1.3 Порядок URL — домен всегда первым

**Файл:** `lib/config/app_config.dart` (стр. 35–46)

- `apiBaseUrls` = cached bootstrap → domain → fallbacks → direct IP.
- При блокировке домена оператором каждый запрос ждёт таймауты по домену.
- **Рекомендация:** Добавить режим «приоритет IP» при повторных сбоях DNS.

---

## 2. Архитектурные конфликты

### 2.1 Три отдельных Dio-инстанса

| Сервис | Dio | URL fallback | IPv4 | SSL для IP |
|--------|-----|--------------|------|------------|
| **ApiClient** | свой | `apiBaseUrls` | да | да |
| **AuthService** | свой | `_apiBaseUrls` | да | да |
| **ConnectionLogger** | свой | **нет** | да | **нет** |

- Разные конфиги, retry, таймауты.
- ConnectionLogger не использует fallback и не настроен для IP.

### 2.2 Bootstrap — асинхронный старт

**Файл:** `lib/services/auth_service.dart` (стр. 597–605)

- `fetchBootstrapUrls()` вызывается в `_loadToken().whenComplete()` — **асинхронно**.
- До завершения bootstrap: `cachedApiBaseUrls == null` → используется fallback `[apiBaseUrl, fallbacks, apiDirectIpUrl]`.
- **Риск:** Первый connect может быть до bootstrap — тогда fallback уже есть, но порядок URL не оптимизирован.

---

## 3. Таймауты и retry

### 3.1 ApiClient retry — тот же URL

**Файл:** `lib/core/api/api_client.dart` (стр. 194–198)

- Retry повторяет **тот же** запрос (тот же URL) через 500 ms.
- Перебор URL делается в `get/post/put/delete` — при ошибке retryable переходим к следующему base.
- **Вывод:** Логика корректна; retry даёт второй шанс текущему URL.

### 3.2 Create-client — 20–25 с receive

**Файл:** `lib/core/api/network_timeouts.dart` (стр. 86–102)

- Mobile: connect 5s, send 10s, receive **20s**.
- WiFi: connect 8s, send 20s, receive **25s**.
- При синхронном apply на бэкенде Celery может занимать до 25–30 с.
- **Риск:** Пользователь ждёт до 20–25 с.

### 3.3 ConnectionLogger — без connectTimeout в extra

**Файл:** `lib/services/connection_logger.dart` (стр. 424–437)

- `sendTimeout` и `receiveTimeout` заданы, но `connectTimeout` не передаётся через `extra['grani_connect_timeout']`.
- Dio использует BaseOptions `connectTimeout: 10s` — для логов приемлемо.

---

## 4. Потенциальные race conditions

### 4.1 Navigator.of при logout

**Файл:** `lib/main.dart` (стр. 351–355)

```dart
if (mounted && context.mounted) {
  Navigator.of(context).pushNamedAndRemoveUntil('/', (_) => false);
}
```

- `Navigator.of(context)` может выбросить, если в дереве нет Navigator.
- **Рекомендация:** Использовать `Navigator.maybeOf(context)?.pushNamedAndRemoveUntil(...)`.

### 4.2 Конкурентные refresh token

**Файл:** `lib/core/api/api_client.dart` (стр. 136–166)

- Mutex `_refreshInProgress` — один refresh при 401, остальные ждут.
- **Вывод:** Реализация корректна.

---

## 5. Серверная сторона (из логов)

**Файл:** `logs/server/vpn-server-check-2026-03-18.md`

- Частые рестарты Xray (16–17 марта) — обрывают соединения.
- `i/o timeout`, `broken pipe` — нестабильная сеть или короткие таймауты.
- **Рекомендация:** Проверить причину рестартов Xray; при необходимости увеличить таймауты.

---

## 6. Сводка рекомендаций

| Приоритет | Проблема | Действие |
|-----------|----------|----------|
| **P0** | ConnectionLogger без fallback | Добавить перебор `AppConfig.apiBaseUrls`, Host header и bad cert для IP |
| **P0** | DNS 5 с на запрос | Уменьшить timeout до 2–3 с; рассмотреть параллельный запрос domain+IP |
| **P1** | Navigator crash при logout | Заменить на `Navigator.maybeOf(context)` |
| **P1** | ConnectionLogger без SSL для IP | Добавить `badCertificateCallback` и `sniHostWhenConnectingByIp` |
| **P2** | Приоритет IP при сбоях DNS | Кэшировать «домен медленный» и переключать порядок URL |
| **P2** | Рестарты Xray на сервере | Проверить cron/деплой; стабилизировать рестарты |

---

## 7. Причины «тормозов» при работающем интернете

1. **DNS** — медленный резолв api.granilink.com (до 5 с на запрос).
2. **Порядок URL** — домен первым; при блокировке/задержке ждём таймауты.
3. **ConnectionLogger** — без fallback; при блокировке домена логи не уходят, но это не блокирует основной UI.
4. **Create-client** — 20–25 с receive; при медленном бэкенде пользователь долго ждёт.
5. **Сервер** — рестарты Xray обрывают соединения; после reconnect часть сайтов может «подвисать».

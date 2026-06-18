---
name: EndpointRouter network refactor
overview: Единый EndpointRouter ([mobile-app/lib/core/api/endpoint_router.dart](mobile-app/lib/core/api/endpoint_router.dart)); ApiClient только исполняет RouteDecision; bootstrap — два явных шага только в AuthService (не в Router/ApiClient); vpnControl — domain или domain+IP по строгому recentFailure; PreferredRouteStorage без ordering; вырезать Dio retry, hedged, SOCKS, multi-base вне ApiClient.
todos:
  - id: router-module
    content: "endpoint_router.dart: resolve({path, kind, wave?}), RouteDecision с assert; правила AUTH/BOOTSTRAP waves/vpnControl/logging; recentFailure для vpnControl"
    status: pending
  - id: preferred-metrics
    content: "PreferredRouteStorage: метрики + recent network failure (timestamp, kind); убрать getOrdered*; Router читает failure для vpnControl"
    status: pending
  - id: cpc-strip
    content: "ControlPlaneClient: удалить Dio retry + авто-SOCKS; без выбора URL"
    status: pending
  - id: apiclient-rewrite
    content: "ApiClient: цикл по decision + reportRouteFailure между базами; без hedged/preferred; финальный resolve API"
    status: pending
  - id: auth-bootstrap-split
    content: "AuthService: bootstrapHostname() и bootstrapDirect() — два отдельных await; внутри — только ApiClient; убрать _postWithRetryAndFallbacks"
    status: pending
  - id: conn-logger
    content: "ConnectionLogger: только ApiClient; очередь _maxRequeueAttempts = бизнес-retry, не HTTP-слой"
    status: pending
  - id: wire-callers
    content: VpnService path→RequestKind; инварианты assert
    status: pending
  - id: tests-analyze
    content: Тесты EndpointRouter + dart analyze
    status: pending
isProject: false
---

# EndpointRouter: единая маршрутизация (ревизия ТЗ)

## Критические исправления (зафиксировано)

### 1) Bootstrap — никакого «скрытого» fallback внутри одного сценария Router/ApiClient

**Запрещено:** один `resolve`, который внутри цепляет hostname → IP; или один метод `fetchBootstrap`, который неявно делает обе волны через общий helper без ветвления в AuthService.

**Обязательно в [AuthService](mobile-app/lib/services/auth_service.dart):** два **явных** шага на верхнем уровне `_fetchBootstrapUrlsInternal` (или эквивалент), читаемо в коде:

```dart
final okHost = await _bootstrapHostnameWave();
if (!okHost) {
  await _bootstrapDirectWave();
}
```

- `_bootstrapHostnameWave` / `_bootstrapDirectWave` вызывают **только** `ApiClient.get` (или единый приватный `_getBootstrapOnce` с `BootstrapWave.hostname` / `BootstrapWave.direct`).
- **Router** по-прежнему возвращает decision **для одной волны за вызов** (`wave: BootstrapWave.hostname` или `wave: BootstrapWave.direct`), но **не** объединяет волны в одном `resolve`.
- **ApiClient** не знает про «если hostname упал — зови IP»; только выполняет `RouteDecision` для переданных `path/kind/wave`.

### 2) vpnControl и health — правило `recentFailure(domain)`

**Проблема:** первый запрос только на domain (fail), между запросами обновился health → второй запрос внезапно с domain+IP — недетерминированно.

**Правило:**

- По умолчанию: `bases = [domain]`, `maxAttempts = 1`.
- Если `hasRecentNetworkFailure(domain)` — тогда `bases = [domain, ip]`, `maxAttempts = bases.length` (2).

Условия `recent` (внедрить явно в [PreferredRouteStorage](mobile-app/lib/core/api/preferred_route_storage.dart) или соседнем слое метрик):

- Окно времени, например **< 30 с** с момента фиксации фейла.
- Тип фейла: **network-class** (connectionError, connectionTimeout и т.п. по согласованной таблице), **не** только HTTP 4xx от «живого» сервера (уточнить в коде комментарием).

`EndpointRouter` при `RequestKind.vpnControl` **читает** эти флаги и строит список баз **до** отправки запроса (детерминированно для данного состояния хранилища).

### 3) Logging — транспорт vs очередь

- **Transport:** ровно **одна** HTTP-попытка на flush (`maxAttempts = 1`, один base) — без Dio-retry и без второй базы.
- **Очередь** [`_maxRequeueAttempts`](mobile-app/lib/services/connection_logger.dart) — **бизнес-повтор** (вернуть batch в очередь). Это не «второй слой HTTP retry» к тому же запросу в одном flush при успешной семантике transport.

Зафиксировать в комментарии рядом с `_flushLogs`: *transport 1×; requeue — отдельная политика очереди.*

---

## Финальный интерфейс EndpointRouter

Файл: [mobile-app/lib/core/api/endpoint_router.dart](mobile-app/lib/core/api/endpoint_router.dart)

```dart
enum RequestKind { auth, bootstrap, vpnControl, logging }

enum BootstrapWave { hostname, direct }

class EndpointRouter {
  static Future<RouteDecision> resolve({
    required String path,
    required RequestKind kind,
    BootstrapWave? wave, // обязателен для kind == bootstrap
  });
}

class RouteDecision {
  final List<Uri> bases;
  final int maxAttempts;

  const RouteDecision({
    required this.bases,
    required this.maxAttempts,
  }) : assert(bases.length <= 2),
       assert(maxAttempts <= 2);
}
```

Примечания:

- Для `kind == bootstrap` вызывающий **всегда** передаёт `wave` (hostname или direct); два разных вызова `resolve` — по одному на волну, **из двух методов AuthService**, не из одного комбинированного resolve.

---

## Жёсткие правила маршрутов


| Kind           | Условие                                     | bases                                                                    | maxAttempts                                                                |
| -------------- | ------------------------------------------- | ------------------------------------------------------------------------ | -------------------------------------------------------------------------- |
| **auth**       | всегда                                      | `[domain]` из `AppConfig.apiBaseUrl`                                     | **1** — без health, без IP, без ветвлений                                  |
| **bootstrap**  | `wave == hostname`                          | `[domain1, domain2]` (ровно два hostname-кандидата из политики продукта) | **2**                                                                      |
| **bootstrap**  | `wave == direct`                            | `[ip1, ip2]` (до двух IP-origin)                                         | **2** — **только** если hostname-волна в AuthService завершилась неуспехом |
| **vpnControl** | нет recent failure на domain                | `[domain]`                                                               | **1**                                                                      |
| **vpnControl** | есть `recentFailure(domain)` (сеть, < 30 с) | `[domain, ip]`                                                           | **2** (= `bases.length`)                                                   |
| **logging**    | всегда                                      | `[domain]`                                                               | **1**                                                                      |


---

## ApiClient — финальная логика исполнения

Псевдокод (после `decision = await EndpointRouter.resolve(...)`):

```dart
for (var i = 0; i < decision.maxAttempts; i++) {
  final base = decision.bases[i];
  try {
    return await _execute(base, path, ...);
  } catch (e) {
    if (i == decision.maxAttempts - 1) rethrow;
    await PreferredRouteStorage.reportRouteFailure(base, path: path);
  }
}
```

- Между попытками — только `reportRouteFailure` (и при необходимости обновление метки **recent network failure** для domain — в том же слое, что читает Router для vpnControl).
- Нет hedged, нет preferred-ordering в ApiClient, нет задержек «между базами для auth».

---

## Чего не должно остаться (чеклист ревью PR)

- Глобальный **Dio retry** (`_shouldRetry` / `_retryRequest`) в ControlPlaneClient.
- **Hedged** параллельные GET в ApiClient.
- **Любой** multi-base / перебор URL вне ApiClient (ConnectionLogger, AuthService helpers).
- **Fallback** внутри AuthService (старый `_postWithRetryAndFallbacks` с несколькими базами / retries).
- **Авто fallback** в ControlPlaneClient (SOCKS), кроме явного флага, если когда-либо понадобится (по умолчанию выкл.).
- `getOrderedApiBaseUrlsForPath` / публичное упорядочивание в PreferredRouteStorage как decision layer.

---

## Остальные файлы (кратко)

- [PreferredRouteStorage](mobile-app/lib/core/api/preferred_route_storage.dart): `saveSuccessfulRoute`, `reportRouteFailure`, кэш для **recent network failure** + существующий health map по необходимости; **удалить** ordering API.
- [ControlPlaneClient](mobile-app/lib/core/vpn/control_plane_client.dart): один Dio; полный URL от ApiClient; без retry/SOCKS/auto-routing.
- [ConnectionLogger](mobile-app/lib/services/connection_logger.dart): только ApiClient; убрать вложенные `for (base)`.
- [VpnService](mobile-app/lib/services/vpn_service.dart): все вызовы через обновлённый ApiClient с картой path → RequestKind.

---

## Порядок внедрения

1. Метрики + `recentFailure` в storage; EndpointRouter + тесты.
2. Вырезать retry/SOCKS из ControlPlaneClient.
3. Переписать ApiClient (цикл + reportRouteFailure).
4. AuthService: разделить bootstrap на два метода; убрать `_postWithRetryAndFallbacks`.
5. ConnectionLogger на ApiClient; задокументировать transport vs queue.
6. Удалить публичный ordering API (`getOrderedApiBaseUrls*`) и мёртвый код.

---

## Риски

- Холодный старт без parallel bootstrap race — медленнее; смягчать только таймаутами волны hostname, не параллельным дублированием без согласования (нарушает ТЗ).

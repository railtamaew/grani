# Мониторинг: `POST /api/vpn/session/prepare`

## Структурированные логи

После выката в логах API ищите строку с префиксом **`[session_prepare]`**.

Формат (одна строка на запрос):

```text
[session_prepare] user_id=<id> server_id=<n> protocol=<xray_*|...> status=<HTTP> elapsed_ms=<ms>
```

- **`elapsed_ms`** — полное время обработки эндпоинта (успех или ошибка).
- **`status`** — итоговый HTTP-код ответа (200 при успехе; 401/400/500 и т.д. при ошибках).
- **`user_id`** — извлекается до вызова бизнес-логики; при ошибке авторизации может остаться `unknown`.

## Проверка выката на проде

Если маршрут **не задеплоен**, обратный прокси отдаёт **404** до приложения (в логах API не будет строки `[session_prepare]`).

Быстрая проверка снаружи (ожидается **401** с невалидным токеном — маршрут есть; **404** — выкатить актуальный `backend`):

```bash
curl -sS -o /dev/null -w "%{http_code}\n" -X POST "https://api.granilink.com/api/vpn/session/prepare" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer invalid" \
  -d '{"server_id":1,"protocol":"xray_vless"}'
```

Для сравнения, устаревший но рабочий путь Xray (должен быть **401**, не 404):

```bash
curl -sS -o /dev/null -w "%{http_code}\n" -X POST "https://api.granilink.com/api/vpn/xray/create-client" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer invalid" \
  -d '{"server_id":1,"protocol":"xray_vless"}'
```

Мобильное приложение после правок при **404** на `session/prepare` автоматически вызывает `create-client` до обновления сервера.

Собирайте метрики в вашем стеке (Loki, CloudWatch, ELK): парсинг по ключу `session_prepare`, агрегации p50/p95 по `elapsed_ms`, доля `status != 200`.

## Связь с общими метриками HTTP

В приложении уже учитываются запросы middleware’ом (путь, метод, статус). Имеет смысл дублировать дашборд для маршрута, соответствующего **`/api/vpn/session/prepare`** (или нормализованного path в вашей реализации метрик), и сопоставлять с логами `[session_prepare]`.

## Алерты (ориентиры)

- Резкий рост доли `status=5xx` или `status=401` на `session_prepare`.
- Рост p95 `elapsed_ms` относительно базовой линии после деплоя (проблемы БД, SSH к нодам, таймауты Xray).

## Клиент

Flutter логирует этапы подключения внутри `VpnService` / обработчиков; для времени до первого успешного конфига смотрите сетевой слой и тайминги `session/prepare` на стороне API выше.

## Готовые запросы (копипаст)

### journalctl (systemd unit API)

```bash
journalctl -u your-api.service --since "1 hour ago" | grep '\[session_prepare\]'
```

Доля ошибок за последний час (пример, если `status=` всегда присутствует):

```bash
journalctl -u your-api.service --since "1 hour ago" | grep '\[session_prepare\]' | grep -c 'status=200'   # успехи
journalctl -u your-api.service --since "1 hour ago" | grep '\[session_prepare\]' | grep -cE 'status=(4|5)' # 4xx/5xx
```

### Loki / LogQL (если логи попадают в Loki)

Базовый фильтр по подстроке (подставьте свой `job` / `service_name`):

```logql
count_over_time({job="api"} |= `[session_prepare]` [6h])
```

Долю неуспешных ответов удобно считать после `| regexp` или `| logfmt` под ваш реальный формат строки; минимальный вариант — два запроса с `|= "status=200"` и без него, либо один запрос с `| line_format` и агрегацией в recording rule.

### HTTP middleware проекта

В `backend/core/metrics.py` агрегируются длительности по пути запроса. Имеет смысл на дашборде смотреть тот же route, что и у `POST .../session/prepare`, и сопоставлять с логами `[session_prepare]` по времени деплоя и всплескам p95.

Ключ в снимке метрик (после матчинга FastAPI route): **`POST /api/vpn/session/prepare`** — смотрите `metrics_registry.snapshot()["requests"]["routes"]` или эндпоинт админки, если он отдаёт этот JSON.

---

## Дашборды и алерты (эксплуатация)

Заполните в своей системе мониторинга (Grafana + Loki / CloudWatch Logs Insights / ELK). В репозитории фиксируются только шаблоны запросов.

### Панель 1: объём и латентность по логам `[session_prepare]`

- **Поток ошибок (1h):** доля строк без `status=200` среди всех `[session_prepare]` за окно.
- **p50 / p95 elapsed_ms:** извлечь число после `elapsed_ms=` (regex `elapsed_ms=(\d+)`) и агрегировать в вашем движке (в LogQL ниже — через `pattern` или двухшаговый запрос).

Пример **Grafana Loki** (подставьте свой `service_name` / `container`):

```logql
sum(count_over_time({service_name="api"} |= `[session_prepare]` |= `status=200` [5m]))
  /
sum(count_over_time({service_name="api"} |= `[session_prepare]` [5m]))
```

Доля **неуспеха**: `1 -` выражение выше, или отдельно считать `|~ "status=(4|5)"`.

### Панель 2: HTTP middleware — тот же маршрут

Сопоставляйте всплески **p95** по ключу `POST /api/vpn/session/prepare` в ответе `/api/admin/.../metrics` (или как у вас экспортируется `metrics_registry`) с всплесками `elapsed_ms` в логах за тот же интервал.

### Алерты (Prometheus / Grafana Alerting)

| Условие | Порог (настроить под базовую линию) |
|--------|-------------------------------------|
| Доля `status=5xx` или `status=401` среди `[session_prepare]` за 15m | \> X% от недельной медианы или абсолютно \> 5% |
| p95 `elapsed_ms` из логов за 15m | \> 2× медиана за 7 дней |
| Нет ни одной строки `[session_prepare]` за 1h при ожидаемом трафике | firing (сломался логгер или маршрут) |

**Заметка:** пороги не хранятся в коде — зависят от нагрузки; после первого месяца наблюдений зафиксируйте числа в runbook команды.

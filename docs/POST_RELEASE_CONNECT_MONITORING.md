# Post-release мониторинг подключения (готовый шаблон)

Документ для первых 24-48 часов после выката изменений ускорения connect-path.

## Периоды контроля

- `T0-T6h`: каждые 30 минут.
- `T6-T24h`: каждый 1 час.
- `T24-T48h`: 2-3 контрольных среза.

## KPI (цели)

- `tap_to_connected_ms`:
  - p50 <= 8000 ms
  - p95 <= 15000 ms
- Повторный connect к тому же серверу: p95 <= 5000 ms.
- Снижение `connected_degraded_retry` минимум на 50% относительно baseline.
- Отсутствие всплеска таймаутов по stage `get_config` и `apply_protocol`.

## Дашборд: обязательные виджеты

1. **Latency overview**
   - p50/p95 `tap_to_connected_ms` (5m, 1h окна).
2. **Stage timeout errors**
   - `vpn_connect_timeout stage=...` по стадиям.
3. **Connection outcome**
   - success/error rate (%).
4. **Degraded signals**
   - `connected_degraded_retry` count.
5. **Apply-state health**
   - `status=applied/queued/failed`
   - `reason_code=dataplane_not_ready_after_apply`
6. **Network split**
   - wifi vs mobile по latency и error rate.

## Быстрые SQL-срезы (PostgreSQL)

Ниже запросы под таблицу `client_logs` (и связанные), ориентированные на текущую схему проекта.

### 1) p50/p95 connect time за период

```sql
WITH base AS (
  SELECT
    created_at,
    protocol,
    connection_duration_ms
  FROM client_logs
  WHERE created_at >= NOW() - INTERVAL '24 hours'
    AND event_type = 'connection_end'
    AND connection_duration_ms IS NOT NULL
    AND connection_duration_ms > 0
)
SELECT
  protocol,
  COUNT(*) AS samples,
  percentile_cont(0.50) WITHIN GROUP (ORDER BY connection_duration_ms) AS p50_ms,
  percentile_cont(0.95) WITHIN GROUP (ORDER BY connection_duration_ms) AS p95_ms,
  AVG(connection_duration_ms)::bigint AS avg_ms
FROM base
GROUP BY protocol
ORDER BY protocol;
```

### 2) Ошибки по stage (таймауты/ключевые этапы)

```sql
SELECT
  date_trunc('hour', created_at) AS ts_hour,
  protocol,
  COALESCE(error_details->>'stage', 'unknown') AS stage,
  COUNT(*) AS errors
FROM client_logs
WHERE created_at >= NOW() - INTERVAL '24 hours'
  AND event_type = 'connection_error'
GROUP BY 1,2,3
ORDER BY ts_hour DESC, protocol, stage;
```

### 3) Доля degraded retry

```sql
WITH all_stages AS (
  SELECT
    protocol,
    COUNT(*) FILTER (WHERE message = 'connected_degraded_retry') AS degraded_count,
    COUNT(*) FILTER (WHERE event_type = 'connection_start') AS starts_count
  FROM client_logs
  WHERE created_at >= NOW() - INTERVAL '24 hours'
    AND protocol IN ('xray_vless', 'xray_reality', 'xray_vmess')
  GROUP BY protocol
)
SELECT
  protocol,
  degraded_count,
  starts_count,
  CASE WHEN starts_count > 0
    THEN ROUND((degraded_count::numeric / starts_count::numeric) * 100, 2)
    ELSE 0 END AS degraded_rate_pct
FROM all_stages
ORDER BY protocol;
```

### 4) Разрез по сети (wifi/mobile)

```sql
SELECT
  protocol,
  COALESCE(error_details->>'network_type', 'unknown') AS network_type,
  COUNT(*) FILTER (WHERE event_type = 'connection_error') AS errors,
  COUNT(*) FILTER (WHERE event_type = 'connection_start') AS starts
FROM client_logs
WHERE created_at >= NOW() - INTERVAL '24 hours'
GROUP BY protocol, network_type
ORDER BY protocol, network_type;
```

### 5) Apply-state: false positive guard

```sql
SELECT
  date_trunc('hour', created_at) AS ts_hour,
  COUNT(*) AS total_errors,
  COUNT(*) FILTER (
    WHERE error_details::text ILIKE '%dataplane_not_ready_after_apply%'
  ) AS dataplane_not_ready_after_apply
FROM client_logs
WHERE created_at >= NOW() - INTERVAL '24 hours'
  AND event_type = 'connection_error'
GROUP BY 1
ORDER BY ts_hour DESC;
```

## Операционные триггеры (когда откатывать/вмешиваться)

- p95 `tap_to_connected_ms` > 20000 ms дольше 60 минут.
- Ошибки stage `get_config` или `apply_protocol` выросли >2x от baseline.
- `dataplane_not_ready_after_apply` > 5% от всех xray-ошибок за час.
- `connected_degraded_retry` не снижается после anti-scan мер.

## План реакции

1. Проверить `xray-v2` active + listening ports на ноде.
2. Проверить текущий шум/баны:
   - `fail2ban-client status xray-v2-noise`
   - `iptables -S XRAYV2_GUARD`
3. Проверить долю fallback на `xray_reality`.
4. Если нужен hotfix:
   - увеличить timeout только для `get_config` на +10s (временно),
   - не трогать сразу весь pipeline.

## Команды быстрого on-call среза

```bash
# fail2ban
sudo fail2ban-client status xray-v2-noise

# iptables guard
sudo iptables -S XRAYV2_GUARD
sudo iptables -S INPUT | rg XRAYV2_GUARD

# unit + порты
systemctl is-active xray-v2
ss -ltnp | rg ':4443|:2053|:8443'
```


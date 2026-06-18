# Performance and Observability

## Backend Metrics

The backend exposes an admin-only metrics endpoint:

- URL: `/api/admin/metrics`
- Auth: Admin JWT token (same as admin panel)
- Output: JSON with request timing summaries and DB query timing

This endpoint is useful for quick verification during load tests and regression checks.

## VPN and auth endpoints to monitor

Track these routes in `/api/admin/metrics` (and/or Nginx/APM) for timeouts and 5xx:

| Route | Purpose | Watch for |
|-------|---------|-----------|
| `GET /api/vpn/bootstrap` | Config for app | p95 &lt; 500ms, 5xx = 0 |
| `POST /api/auth/send-code` | Email code | p95 &lt; 5s (SES), 5xx = 0 |
| `POST /api/auth/verify-code` | Login | p95 целевой &lt; 2s; на мобильной сети допускаются пики (БД/почта) — клиент receive до ~18s |
| `POST /api/vpn/session/prepare` | Выдача конфига (предпочтительно) | Должен отвечать **не 404**; см. [OPS_SESSION_PREPARE_METRICS.md](./OPS_SESSION_PREPARE_METRICS.md) |
| `POST /api/vpn/xray/create-client` | Xray client creation (legacy / fallback) | p95 &lt; 10s (SSH/Celery), 5xx = 0 |
| `GET /api/vpn/servers` | Server list | p95 &lt; 300ms |
| `GET /health` | Liveness | 200, low latency |

- **Timeouts:** If Nginx or Gunicorn report upstream timeouts, correlate with these routes and DB/Redis/SSH latency.
- **5xx:** Check `requests.status_counts` in metrics for `* 500` and `* 502`; investigate logs and DB/Redis/Celery.
- See also `docs/SERVER_OVERLOAD_ANALYSIS.md` for past overload analysis and Redis/Celery recommendations.

## Load Testing Script

Use the lightweight load test script:

```bash
API_BASE_URL="http://localhost:8000" \
API_PATH="/api/vpn/servers" \
API_TOKEN="YOUR_JWT_TOKEN" \
TOTAL_REQUESTS=1000 \
CONCURRENCY=100 \
python /opt/grani/scripts/load_test_api.py
```

For health endpoint (no auth):

```bash
API_PATH="/health" TOTAL_REQUESTS=1000 CONCURRENCY=100 python /opt/grani/scripts/load_test_api.py
```

## Suggested Baseline Targets

- API latency p95: < 300ms for `/api/vpn/servers`
- Error rate: < 1%
- DB slow queries: 0 for core endpoints under normal load

## Mobile Profiling Quick Notes

- Run: `flutter run --profile` to capture startup and UI performance.
- Use Flutter DevTools to check frame jank and startup timeline.
- Focus on startup time, server refresh flow, and VPN connect flow.

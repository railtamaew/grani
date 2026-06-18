# Диагностика VPN-клиента (lifecycle)

Набор скриптов по [docs/VPN_CLIENT_LIFECYCLE_DIAGNOSTICS_PLAN.md](../../docs/VPN_CLIENT_LIFECYCLE_DIAGNOSTICS_PLAN.md).

| Шаг плана | Скрипт |
|-----------|--------|
| Зафиксировать окно, logcat, опционально dumpsys | [capture_client_incident.sh](./capture_client_incident.sh) |
| Docker Nginx / API / Celery за окном | [docker_correlation_window.sh](./docker_correlation_window.sh) |
| Postgres users / devices / `client_logs` | [postgres_client_logs_timeline.sh](./postgres_client_logs_timeline.sh) + `query_user_client_logs_window.sql` |
| Разбор logcat по матрице §5–8 | [logcat_protocol_matrix.sh](./logcat_protocol_matrix.sh) |
| По `connection_session_id` | [../../server-config/scripts/client_logs_correlation.sh](../../server-config/scripts/client_logs_correlation.sh) |

**Нода HU-BUD-01 (read-only, ключ из БД):**

```bash
cd /opt/grani/backend && PYTHONPATH=/opt/grani/backend python3 scripts/diagnostics_hu_bud_data_plane.py
```

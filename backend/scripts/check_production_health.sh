#!/usr/bin/env bash
# Проверка доступности API (health). Для cron или мониторинга.
# Использование:
#   На сервере (после деплоя): API_HEALTH_URL=http://127.0.0.1:8010/health ./scripts/check_production_health.sh
#   Извне: API_HEALTH_URL=https://api.granilink.com/health ./scripts/check_production_health.sh
# По умолчанию: http://127.0.0.1:8010/health (порт API в docker-compose на хосте)
set -e
url="${API_HEALTH_URL:-http://127.0.0.1:8010/health}"
code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 30 "$url" || true)
if [ "$code" = "200" ]; then
  echo "OK health $code $url"
  exit 0
fi
echo "FAIL health HTTP $code $url" >&2
exit 1

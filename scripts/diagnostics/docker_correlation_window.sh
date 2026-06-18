#!/usr/bin/env bash
# Шаг 3 плана: Nginx (access) → API → Celery за временным окном.
#
# Использование:
#   ./docker_correlation_window.sh --since "2026-04-24T12:00:00" --until "2026-04-24T13:00:00"
#   ./docker_correlation_window.sh --since 1h
#
# Переменные:
#   GRANI_REPO — корень репозитория (по умолчанию /opt/grani или родитель scripts/diagnostics)
#
set -euo pipefail

SINCE=""
UNTIL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="${2:-}"; shift 2 ;;
    --until) UNTIL="${2:-}"; shift 2 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$SINCE" ]]; then
  echo "Укажите --since \"RFC3339\" или относительное время (1h, 30m)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRANI_REPO="${GRANI_REPO:-}"
if [[ -z "$GRANI_REPO" ]]; then
  if [[ -d /opt/grani/logs/docker-nginx ]]; then
    GRANI_REPO=/opt/grani
  else
    GRANI_REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
  fi
fi
NGINX_HOST_LOG="${GRANI_REPO}/logs/docker-nginx/access.log"
GREP_RE='session/prepare|/vpn/logs/send|/health|/api/vpn/'

echo "=== GRANI_REPO=$GRANI_REPO since=$SINCE until=${UNTIL:-(нет)} ==="
echo ""

echo "--- Nginx access (хостовый том, если есть) ---"
if [[ -f "$NGINX_HOST_LOG" ]]; then
  # shellcheck disable=SC2086
  grep -E "$GREP_RE" "$NGINX_HOST_LOG" 2>/dev/null | tail -300 || true
else
  echo "Файл не найден: $NGINX_HOST_LOG — пробую docker logs granivpn_nginx"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx granivpn_nginx; then
    if [[ -n "$UNTIL" ]]; then
      docker logs granivpn_nginx --since "$SINCE" --until "$UNTIL" 2>&1 | grep -E "$GREP_RE" | tail -300 || true
    else
      docker logs granivpn_nginx --since "$SINCE" 2>&1 | grep -E "$GREP_RE" | tail -300 || true
    fi
  else
    echo "Контейнер granivpn_nginx не запущен."
  fi
fi

echo ""
echo "--- API granivpn_api ---"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx granivpn_api; then
  if [[ -n "$UNTIL" ]]; then
    docker logs granivpn_api --since "$SINCE" --until "$UNTIL" 2>&1 \
      | grep -E 'session/prepare|user_id|req_id|X-Request-ID|500|422' | tail -400 || true
  else
    docker logs granivpn_api --since "$SINCE" 2>&1 \
      | grep -E 'session/prepare|user_id|req_id|X-Request-ID|500|422' | tail -400 || true
  fi
else
  echo "Контейнер granivpn_api не запущен."
fi

echo ""
echo "--- Celery granivpn_celery (save_client_logs) ---"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx granivpn_celery; then
  if [[ -n "$UNTIL" ]]; then
    docker logs granivpn_celery --since "$SINCE" --until "$UNTIL" 2>&1 \
      | grep -iE 'save_client_logs|client_log|error|Traceback' | tail -200 || true
  else
    docker logs granivpn_celery --since "$SINCE" 2>&1 \
      | grep -iE 'save_client_logs|client_log|error|Traceback' | tail -200 || true
  fi
else
  echo "Контейнер granivpn_celery не запущен."
fi

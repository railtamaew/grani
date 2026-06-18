#!/usr/bin/env bash
# Выборки client_logs для склейки с logcat (connection_session_id, prewarm, reconnect).
# Требуется: контейнер granivpn_postgres (docker compose из server-config/docker).
#
# Использование:
#   ./client_logs_correlation.sh
#   ./client_logs_correlation.sh '1776777872392_4263'
#
# Переменные окружения:
#   POSTGRES_CONTAINER — имя контейнера (по умолчанию granivpn_postgres)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="${SCRIPT_DIR}/query_client_logs_correlation.sql"
CONTAINER="${POSTGRES_CONTAINER:-granivpn_postgres}"
SESSION="${1:-___NO_MATCH_SESSION___}"

if [[ ! -f "$SQL_FILE" ]]; then
  echo "Не найден файл: $SQL_FILE" >&2
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Контейнер PostgreSQL не запущен: $CONTAINER" >&2
  exit 1
fi

echo "Контейнер: $CONTAINER | connection_session_id (запрос 1): $SESSION"
cat "$SQL_FILE" | docker exec -i "$CONTAINER" psql -U granivpn_user -d granivpn -v "session=$SESSION" -f -

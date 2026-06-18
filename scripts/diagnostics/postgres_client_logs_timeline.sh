#!/usr/bin/env bash
# Postgres: users / devices / client_logs за окном (план §3.1–3.2).
#
# Использование:
#   ./postgres_client_logs_timeline.sh 'user@example.com' '2026-04-24 12:20:00+00' '2026-04-24 13:00:00+00'
#
# Переменные:
#   POSTGRES_CONTAINER — по умолчанию granivpn_postgres
#
set -euo pipefail

EMAIL="${1:-}"
TS_START="${2:-}"
TS_END="${3:-}"

if [[ -z "$EMAIL" || -z "$TS_START" || -z "$TS_END" ]]; then
  echo "Использование: $0 'email' 'ts_start' 'ts_end'  (timestamptz как в SQL, с +00 при UTC)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="${SCRIPT_DIR}/query_user_client_logs_window.sql"
CONTAINER="${POSTGRES_CONTAINER:-granivpn_postgres}"

if [[ ! -f "$SQL_FILE" ]]; then
  echo "Не найден: $SQL_FILE" >&2
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Контейнер не запущен: $CONTAINER" >&2
  exit 1
fi

docker exec -i "$CONTAINER" psql -U granivpn_user -d granivpn \
  -v "email=$EMAIL" \
  -v "ts_start=$TS_START" \
  -v "ts_end=$TS_END" \
  -f - <"$SQL_FILE"

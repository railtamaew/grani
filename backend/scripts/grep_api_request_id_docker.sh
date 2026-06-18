#!/usr/bin/env bash
# Поиск строк API по X-Request-ID из клиента (logcat: X-Request-ID= / x_request_id=).
# Запуск на сервере, где крутится контейнер API (или локально при том же compose).
#
# Примеры:
#   ./backend/scripts/grep_api_request_id_docker.sh a1b2c3d4-e5f6-7890-abcd-ef1234567890
#   GRANI_API_CONTAINER=my_api ./backend/scripts/grep_api_request_id_docker.sh "$RID" --tail 50000
#   ./backend/scripts/grep_api_request_id_docker.sh "$RID" --host-log
#
set -euo pipefail

usage() {
  echo "Usage: $0 <x-request-id> [--container NAME] [--since DURATION] [--tail N] [--host-log [FILE]]" >&2
  echo "  --container   Docker container name (default: \$GRANI_API_CONTAINER or granivpn_api)" >&2
  echo "  --since       docker logs --since (e.g. 30m, 2h)" >&2
  echo "  --tail        docker logs --tail (default: 50000)" >&2
  echo "  --host-log    grep mounted backend log on host instead of/in addition to docker logs" >&2
  exit 1
}

[[ $# -ge 1 ]] || usage
RID="$1"
shift

CONTAINER="${GRANI_API_CONTAINER:-granivpn_api}"
SINCE=""
TAIL="50000"
HOST_LOG=""
DOCKER=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container)
      [[ $# -ge 2 ]] || usage
      CONTAINER="$2"
      shift 2
      ;;
    --since)
      [[ $# -ge 2 ]] || usage
      SINCE="$2"
      shift 2
      ;;
    --tail)
      [[ $# -ge 2 ]] || usage
      TAIL="$2"
      shift 2
      ;;
    --host-log)
      if [[ $# -ge 2 && "$2" != --* ]]; then
        HOST_LOG="$2"
        shift 2
      else
        _root="$(cd "$(dirname "$0")/../.." && pwd)"
        HOST_LOG="${_root}/logs/docker-api/grani-backend.log"
        shift
      fi
      ;;
    *)
      usage
      ;;
  esac
done

if [[ -n "$HOST_LOG" ]]; then
  if [[ ! -f "$HOST_LOG" ]]; then
    echo "File not found: $HOST_LOG" >&2
    exit 1
  fi
  echo "# grep -F in $HOST_LOG" >&2
  if grep -F "$RID" "$HOST_LOG"; then
    exit 0
  fi
  echo "(no matches in host log)" >&2
  exit 1
fi

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "Docker container not found: $CONTAINER (set GRANI_API_CONTAINER or --container)" >&2
  exit 1
fi

LOG_ARGS=(--tail "$TAIL")
if [[ -n "$SINCE" ]]; then
  LOG_ARGS=(--since "$SINCE" --tail "$TAIL")
fi

echo "# docker logs ${LOG_ARGS[*]} $CONTAINER | grep -F <id>" >&2
if docker logs "${LOG_ARGS[@]}" "$CONTAINER" 2>&1 | grep -F "$RID"; then
  exit 0
fi
echo "(no matches; try larger --tail, different --since, or --host-log if logs are file-only)" >&2
exit 1

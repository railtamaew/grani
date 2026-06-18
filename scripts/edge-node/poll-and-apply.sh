#!/usr/bin/env bash
# Poll GET /assignment; для type=apply_xray_config — записать конфиг, restart xray, POST result.
# Требует root (или sudo для systemctl и записи в путь Xray). Запускать реже heartbeat (например раз в 1–2 мин).
set -euo pipefail

: "${GRANI_API_BASE:?Set GRANI_API_BASE}"
: "${GRANI_NODE_ID:?Set GRANI_NODE_ID}"

TOKEN_FILE="${GRANI_NODE_TOKEN_FILE:-/etc/grani-edge/token}"
CONFIG_PATH="${GRANI_XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
SYSTEMD_UNIT="${GRANI_XRAY_SYSTEMD_UNIT:-xray}"
STATE_DIR="${GRANI_EDGE_STATE_DIR:-/var/lib/grani-edge}"
STATE_FILE="${STATE_DIR}/poll.state"
POLL_MIN_EMPTY_SEC="${GRANI_ASSIGNMENT_POLL_MIN_EMPTY_SEC:-180}"
POLL_MIN_WORK_SEC="${GRANI_ASSIGNMENT_POLL_MIN_WORK_SEC:-30}"

if [[ ! -r "$TOKEN_FILE" ]]; then
  echo "poll-and-apply: cannot read token: $TOKEN_FILE" >&2
  exit 1
fi
TOKEN=$(tr -d '\n\r' <"$TOKEN_FILE")
BASE="${GRANI_API_BASE%/}"
AUTH=( -H "Authorization: Bearer ${TOKEN}" )

mkdir -p "$STATE_DIR" 2>/dev/null || true
NOW_TS=$(date +%s)
LAST_TS=0
LAST_EMPTY=true
if [[ -r "$STATE_FILE" ]]; then
  LAST_TS=$(awk -F= '/^last_ts=/{print $2}' "$STATE_FILE" 2>/dev/null || echo 0)
  LAST_EMPTY=$(awk -F= '/^last_empty=/{print $2}' "$STATE_FILE" 2>/dev/null || echo true)
fi
if [[ -z "$LAST_TS" ]]; then LAST_TS=0; fi
MIN_INTERVAL="$POLL_MIN_EMPTY_SEC"
if [[ "$LAST_EMPTY" != "true" ]]; then
  MIN_INTERVAL="$POLL_MIN_WORK_SEC"
fi
DELTA=$((NOW_TS - LAST_TS))
if [[ "$DELTA" -lt "$MIN_INTERVAL" ]]; then
  exit 0
fi

RESP=$(curl -sS -G "${BASE}/api/internal/node/v1/assignment" \
  "${AUTH[@]}" \
  --data-urlencode "node_id=${GRANI_NODE_ID}")

if ! echo "$RESP" | jq -e . >/dev/null 2>&1; then
  echo "poll-and-apply: invalid JSON from API" >&2
  exit 1
fi

if [[ $(echo "$RESP" | jq -r '.assignment') == "null" ]]; then
  {
    echo "last_ts=${NOW_TS}"
    echo "last_empty=true"
  } > "$STATE_FILE" 2>/dev/null || true
  exit 0
fi

{
  echo "last_ts=${NOW_TS}"
  echo "last_empty=false"
} > "$STATE_FILE" 2>/dev/null || true

AID=$(echo "$RESP" | jq -r '.assignment.id')
ATYPE=$(echo "$RESP" | jq -r '.assignment.type')

post_result() {
  local status="$1"
  local msg="$2"
  local hash="${3:-}"
  local reloaded="${4:-}"
  local payload
  payload=$(jq -n \
    --arg st "$status" \
    --arg msg "$msg" \
    --arg h "$hash" \
    --arg rt "$reloaded" \
    '{status:$st, message:$msg, applied_config_hash:(if $h=="" then null else $h end), xray_reloaded_at:(if $rt=="" then null else $rt end)}')
  curl -sS -X POST \
    "${BASE}/api/internal/node/v1/assignment/${AID}/result?node_id=${GRANI_NODE_ID}" \
    "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -d "$payload" -o /dev/null || true
}

if [[ "$ATYPE" != "apply_xray_config" ]]; then
  post_result "failed" "unsupported assignment type: $ATYPE" "" ""
  exit 0
fi

B64=$(echo "$RESP" | jq -r '.assignment.config_b64')
EXPECTED=$(echo "$RESP" | jq -r '.assignment.expected_hash')

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
if ! printf '%s' "$B64" | base64 -d >"$TMP" 2>/dev/null; then
  post_result "failed" "base64 decode failed" "" ""
  exit 0
fi

HASH_RAW=$(sha256sum "$TMP" | awk '{print $1}')
ACTUAL="sha256:${HASH_RAW}"
if [[ -n "$EXPECTED" && "$EXPECTED" != "null" && "$ACTUAL" != "$EXPECTED" ]]; then
  post_result "failed" "config hash mismatch actual=${ACTUAL}" "$ACTUAL" ""
  exit 0
fi

# Если конфиг уже совпадает — не делаем лишний restart.
if [[ -f "$CONFIG_PATH" ]]; then
  CURRENT_RAW=$(sha256sum "$CONFIG_PATH" | awk '{print $1}')
  CURRENT="sha256:${CURRENT_RAW}"
  if [[ "$CURRENT" == "$ACTUAL" ]]; then
    post_result "ok" "config already applied" "$ACTUAL" ""
    exit 0
  fi
fi

install -m 0644 -o root -g root "$TMP" "$CONFIG_PATH" 2>/dev/null || cp "$TMP" "$CONFIG_PATH"

RELOADED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if ! systemctl restart "$SYSTEMD_UNIT" 2>/dev/null; then
  post_result "failed" "systemctl restart ${SYSTEMD_UNIT} failed" "$ACTUAL" ""
  exit 0
fi

if ! systemctl is-active "$SYSTEMD_UNIT" >/dev/null 2>&1; then
  post_result "failed" "${SYSTEMD_UNIT} not active after restart" "$ACTUAL" "$RELOADED"
  exit 0
fi

# Confirm key inbound ports are listening before reporting success.
for port in 2053 4443 8443; do
  ok=0
  for _ in 1 2 3 4 5 6; do
    if ss -ltn "( sport = :${port} )" 2>/dev/null | grep -q ":${port}"; then
      ok=1
      break
    fi
    sleep 1
  done
  if [[ "$ok" != "1" ]]; then
    post_result "failed" "port ${port} is not listening after restart" "$ACTUAL" "$RELOADED"
    exit 0
  fi
done

post_result "ok" "config applied and xray listening" "$ACTUAL" "$RELOADED"

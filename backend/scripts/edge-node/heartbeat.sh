#!/usr/bin/env bash
# Отправка heartbeat на GRANI API (фаза 1). Переменные — из /etc/default/grani-edge или окружения.
set -euo pipefail

: "${GRANI_API_BASE:?Set GRANI_API_BASE}"
: "${GRANI_NODE_ID:?Set GRANI_NODE_ID}"

TOKEN_FILE="${GRANI_NODE_TOKEN_FILE:-/etc/grani-edge/token}"
CONFIG_PATH="${GRANI_XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
AGENT_VERSION="${GRANI_AGENT_VERSION:-1}"
STATE_DIR="${GRANI_EDGE_STATE_DIR:-/var/lib/grani-edge}"
STATE_FILE="${STATE_DIR}/heartbeat.state"
MIN_INTERVAL_OK_SEC="${GRANI_HEARTBEAT_MIN_INTERVAL_OK_SEC:-120}"
MIN_INTERVAL_FAIL_SEC="${GRANI_HEARTBEAT_MIN_INTERVAL_FAIL_SEC:-30}"

if [[ ! -r "$TOKEN_FILE" ]]; then
  echo "grani-edge-heartbeat: cannot read token file: $TOKEN_FILE" >&2
  exit 1
fi
TOKEN=$(tr -d '\n\r' <"$TOKEN_FILE")

if [[ ! -r "$CONFIG_PATH" ]]; then
  echo "grani-edge-heartbeat: config not found: $CONFIG_PATH" >&2
  exit 1
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true

HASH_RAW=$(sha256sum "$CONFIG_PATH" | awk '{print $1}')
CONFIG_HASH="sha256:${HASH_RAW}"

if systemctl is-active --quiet xray 2>/dev/null; then
  XR_JSON=true
else
  XR_JSON=false
fi

NOW_TS=$(date +%s)
LAST_TS=0
LAST_OK=true
if [[ -r "$STATE_FILE" ]]; then
  LAST_TS=$(awk -F= '/^last_ts=/{print $2}' "$STATE_FILE" 2>/dev/null || echo 0)
  LAST_OK=$(awk -F= '/^last_ok=/{print $2}' "$STATE_FILE" 2>/dev/null || echo true)
fi
if [[ -z "$LAST_TS" ]]; then LAST_TS=0; fi

MIN_INTERVAL="$MIN_INTERVAL_OK_SEC"
if [[ "$LAST_OK" != "true" ]]; then
  MIN_INTERVAL="$MIN_INTERVAL_FAIL_SEC"
fi
DELTA=$((NOW_TS - LAST_TS))
if [[ "$DELTA" -lt "$MIN_INTERVAL" ]]; then
  exit 0
fi

BODY=$(jq -n \
  --argjson node_id "$GRANI_NODE_ID" \
  --arg config_hash "$CONFIG_HASH" \
  --argjson xray_running "$XR_JSON" \
  --arg agent_version "$AGENT_VERSION" \
  '{node_id: $node_id, config_hash: $config_hash, xray_running: $xray_running, agent_version: $agent_version}')

BASE="${GRANI_API_BASE%/}"
URL="${BASE}/api/internal/node/v1/heartbeat"

if curl -sS -f -X POST "$URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d "$BODY" \
  -o /dev/null; then
  {
    echo "last_ts=${NOW_TS}"
    echo "last_ok=true"
  } > "$STATE_FILE" 2>/dev/null || true
else
  {
    echo "last_ts=${NOW_TS}"
    echo "last_ok=false"
  } > "$STATE_FILE" 2>/dev/null || true
  exit 1
fi

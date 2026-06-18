#!/usr/bin/env bash
# Проверка второго шага: HTTPS API на 443 и запасном порту (по умолчанию 8444).
# 8443 на HU-BUD — Xray VMESS, не nginx.
set -euo pipefail

NODE_IP="${NODE_IP:-45.12.132.94}"
API_HOST="${API_HOST:-api.granilink.com}"
ALT_PORT="${ALT_PORT:-8444}"

echo "=== dig $API_HOST ==="
dig +short "$API_HOST" A || true

echo "=== 443 GET /api/vpn/bootstrap ==="
code_443=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 12 --max-time 20 \
  "https://${API_HOST}/api/vpn/bootstrap" 2>/dev/null || true)
[[ -z "$code_443" ]] && code_443="000"
echo "http_code=$code_443"

echo "=== ${ALT_PORT} GET /api/vpn/bootstrap ==="
code_alt=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 12 --max-time 20 \
  "https://${API_HOST}:${ALT_PORT}/api/vpn/bootstrap" 2>/dev/null || true)
[[ -z "$code_alt" ]] && code_alt="000"
echo "http_code=$code_alt"

echo "=== ${ALT_PORT} via IP + Host ==="
code_ip=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 12 --max-time 20 -k \
  -H "Host: ${API_HOST}" \
  --resolve "${API_HOST}:${ALT_PORT}:${NODE_IP}" \
  "https://${API_HOST}:${ALT_PORT}/api/vpn/bootstrap" 2>/dev/null || true)
[[ -z "$code_ip" ]] && code_ip="000"
echo "http_code=$code_ip"

if [[ "$code_443" == "200" && "$code_alt" == "200" ]]; then
  echo "OK: второй шаг активен (443 и ${ALT_PORT})."
  exit 0
fi
if [[ "$code_443" == "200" ]]; then
  echo "ВНИМАНИЕ: 443 OK, ${ALT_PORT} не 200 — задеплойте api-proxy.conf и откройте TCP ${ALT_PORT} (облако + ufw)."
  exit 1
fi
echo "ВНИМАНИЕ: 443 не 200 — проверьте DNS, nginx и сертификат."
exit 1

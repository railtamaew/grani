#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v fail2ban-client >/dev/null 2>&1; then
  echo "fail2ban is not installed"
  exit 1
fi

sudo install -m 0644 \
  "$ROOT_DIR/fail2ban/filter.d/xray-v2-noise.conf" \
  /etc/fail2ban/filter.d/xray-v2-noise.conf

sudo install -m 0644 \
  "$ROOT_DIR/fail2ban/jail.d/xray-v2-noise.local" \
  /etc/fail2ban/jail.d/xray-v2-noise.local

sudo systemctl restart fail2ban
sudo fail2ban-client status xray-v2-noise || true

echo "Installed fail2ban jail: xray-v2-noise"

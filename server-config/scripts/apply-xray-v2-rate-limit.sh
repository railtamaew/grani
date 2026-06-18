#!/usr/bin/env bash
set -euo pipefail

# Basic anti-scan guardrails for public Xray ports.
# Compatibility-first version: relies on tcp + limit only
# (no conntrack/state/connlimit dependencies).

PORTS=(4443 2053 8443)
CHAIN_BASELINE="XRAYV2_GUARD"
CHAIN_4443="XRAYV2_4443_CHURN_GUARD"

if ! command -v iptables >/dev/null 2>&1; then
  echo "iptables not found"
  exit 1
fi

if ! iptables -nL "$CHAIN_BASELINE" >/dev/null 2>&1; then
  iptables -N "$CHAIN_BASELINE"
fi

if ! iptables -nL "$CHAIN_4443" >/dev/null 2>&1; then
  iptables -N "$CHAIN_4443"
fi

# Reset chains to keep script idempotent.
iptables -F "$CHAIN_BASELINE"
iptables -F "$CHAIN_4443"

# Allow sane burst of SYN handshakes, then drop.
iptables -A "$CHAIN_BASELINE" -m limit --limit 80/second --limit-burst 160 -j RETURN
iptables -A "$CHAIN_BASELINE" -j DROP

# Extra churn guard for baseline vless@4443:
# stricter SYN gate for :4443 to reduce short-flow storms.
iptables -A "$CHAIN_4443" -m limit --limit 25/second --limit-burst 50 -j RETURN
iptables -A "$CHAIN_4443" -j DROP

for port in "${PORTS[@]}"; do
  # Remove old hooks if present.
  while iptables -C INPUT -p tcp --syn --dport "$port" -j "$CHAIN_BASELINE" >/dev/null 2>&1; do
    iptables -D INPUT -p tcp --syn --dport "$port" -j "$CHAIN_BASELINE"
  done
  iptables -I INPUT -p tcp --syn --dport "$port" -j "$CHAIN_BASELINE"
done

while iptables -C INPUT -p tcp --syn --dport 4443 -j "$CHAIN_4443" >/dev/null 2>&1; do
  iptables -D INPUT -p tcp --syn --dport 4443 -j "$CHAIN_4443"
done
iptables -I INPUT -p tcp --syn --dport 4443 -j "$CHAIN_4443"

echo "Applied XRAY v2 anti-scan + 4443 churn guard on ports: ${PORTS[*]}"

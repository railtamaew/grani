#!/usr/bin/env bash
set -euo pipefail

# Transport tuning for long-lived TCP flows (video/speedtest-like traffic).
# Safe to re-run; writes a dedicated sysctl drop-in file.

CONF_PATH="/etc/sysctl.d/99-grani-xray-transport.conf"

cat <<'EOF' | sudo tee "$CONF_PATH" >/dev/null
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192

net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_tw_reuse = 1
EOF

sudo sysctl --system >/dev/null
echo "Applied transport sysctl tuning: $CONF_PATH"

#!/usr/bin/env bash
set -euo pipefail

apply_changes="false"
if [[ "${1:-}" == "--apply" ]]; then
  apply_changes="true"
fi

config_dir="/etc/ssh/sshd_config.d"
base_config="/etc/ssh/sshd_config"
target_config="$base_config"
if [[ -d "$config_dir" ]]; then
  target_config="${config_dir}/99-grani.conf"
fi

echo "== sshd effective settings =="
if command -v sshd >/dev/null 2>&1; then
  sshd -T 2>/dev/null | grep -E 'clientaliveinterval|clientalivecountmax|maxsessions|tcpkeepalive' || true
else
  grep -E 'ClientAliveInterval|ClientAliveCountMax|MaxSessions|TCPKeepAlive' "$base_config" || true
fi

echo ""
echo "== target config =="
echo "$target_config"

if [[ "$apply_changes" != "true" ]]; then
  echo ""
  echo "Dry run. Re-run with --apply to write settings."
  exit 0
fi

cat <<'EOF' > "$target_config"
# Managed by grani (VPN stability)
ClientAliveInterval 30
ClientAliveCountMax 6
MaxSessions 100
TCPKeepAlive yes
EOF

echo ""
echo "Written $target_config"
echo "Reload with: systemctl reload sshd"

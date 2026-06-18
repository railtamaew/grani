#!/usr/bin/env bash
set -euo pipefail

# nftables-based churn guard for Xray public ports.
# Designed to be idempotent and compatible with nodes where iptables modules are limited.

if ! command -v nft >/dev/null 2>&1; then
  echo "nft command not found"
  exit 1
fi

TABLE_FAMILY="inet"
TABLE_NAME="grani_xray_guard"
CHAIN_NAME="syn_guard"

# Recreate controlled table/chain each run to keep rules deterministic.
nft list table "${TABLE_FAMILY}" "${TABLE_NAME}" >/dev/null 2>&1 || nft add table "${TABLE_FAMILY}" "${TABLE_NAME}"
nft list chain "${TABLE_FAMILY}" "${TABLE_NAME}" "${CHAIN_NAME}" >/dev/null 2>&1 || \
  nft add chain "${TABLE_FAMILY}" "${TABLE_NAME}" "${CHAIN_NAME}" "{ type filter hook input priority 0; policy accept; }"
nft flush chain "${TABLE_FAMILY}" "${TABLE_NAME}" "${CHAIN_NAME}"

# Stricter SYN gate for baseline vless@4443.
nft add rule "${TABLE_FAMILY}" "${TABLE_NAME}" "${CHAIN_NAME}" \
  tcp dport 4443 tcp flags syn / syn limit rate over 25/second burst 50 packets drop

# Baseline SYN gate for other public Xray ports (and 4443 as generic fallback).
nft add rule "${TABLE_FAMILY}" "${TABLE_NAME}" "${CHAIN_NAME}" \
  tcp dport { 2053, 8443, 4443 } tcp flags syn / syn limit rate over 80/second burst 160 packets drop

echo "Applied nft guard in ${TABLE_FAMILY}/${TABLE_NAME}/${CHAIN_NAME}"
nft list chain "${TABLE_FAMILY}" "${TABLE_NAME}" "${CHAIN_NAME}"

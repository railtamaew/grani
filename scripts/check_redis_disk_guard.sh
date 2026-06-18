#!/usr/bin/env bash
# Быстрая проверка места на диске и Redis AOF (симптом MISCONF / no space left on device).
set -euo pipefail
echo "== df (host) =="
df -h . 2>/dev/null || true
df -h /var/lib/docker 2>/dev/null || true

if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx granivpn_redis; then
  echo "== redis INFO persistence (granivpn_redis) =="
  docker exec granivpn_redis redis-cli INFO persistence 2>/dev/null | grep -E '^(aof_enabled|rdb_last_bgsave_status|aof_last_write_status|aof_last_bgrewrite_status):' || true
  echo "== redis DBSIZE =="
  docker exec granivpn_redis redis-cli DBSIZE 2>/dev/null || true
else
  echo "granivpn_redis not running; skip redis exec."
fi

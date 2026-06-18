#!/usr/bin/env bash
# Снимок состояния стека для сравнения до/после (инфра, Redis, Docker).
set -euo pipefail
echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) baseline ==="
echo "--- docker stats ---"
docker stats --no-stream granivpn_api granivpn_nginx granivpn_redis granivpn_postgres 2>/dev/null || true
echo "--- docker system df ---"
docker system df -v 2>/dev/null | head -40 || true
echo "--- redis memory ---"
docker exec granivpn_redis redis-cli INFO memory 2>/dev/null | rg -i "used_memory_human|maxmemory_human|evicted_keys" || true
echo "--- redis dbsize ---"
docker exec granivpn_redis redis-cli DBSIZE 2>/dev/null || true
echo "--- api logs dir (host) ---"
du -sh /opt/grani/logs/docker-api 2>/dev/null || du -sh "$(dirname "$0")/../../logs/docker-api" 2>/dev/null || true
echo "--- done ---"

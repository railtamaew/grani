#!/bin/bash
# Проверка логов бэкенда и nginx на сервере (таймауты API, запросы с устройства).
# Запускать с машины, где настроен SSH-доступ к серверу:
#   ./server-config/check-backend-logs.sh
# или с указанием хоста:
#   GRANI_SERVER_IP=159.223.199.122 ./server-config/check-backend-logs.sh

set -e
SERVER_IP="${GRANI_SERVER_IP:-159.223.199.122}"
SERVER_USER="${GRANI_SERVER_USER:-root}"
LINES="${LINES:-200}"
# Опционально: путь к ключу (например GRANI_SSH_KEY=~/.ssh/grani_vpn_key или путь к ключу в репо)
SSH_KEY_OPT=""
if [ -n "$GRANI_SSH_KEY" ] && [ -f "$GRANI_SSH_KEY" ]; then
  SSH_KEY_OPT="-i $GRANI_SSH_KEY"
fi

echo "=== Логи бэкенда @ $SERVER_USER@$SERVER_IP (последние $LINES строк) ==="
echo ""

# Проверка SSH
if ! ssh $SSH_KEY_OPT -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "$SERVER_USER@$SERVER_IP" "echo OK" >/dev/null 2>&1; then
  echo "Ошибка: нет доступа по SSH к $SERVER_USER@$SERVER_IP"
  echo "Проверьте ключ: ssh $SERVER_USER@$SERVER_IP"
  echo "Или задайте ключ: GRANI_SSH_KEY=/path/to/key $0"
  exit 1
fi

run_remote() {
  ssh $SSH_KEY_OPT -o StrictHostKeyChecking=no "$SERVER_USER@$SERVER_IP" "$@"
}

echo "--- 1. Nginx access.log (последние запросы к /api) ---"
run_remote "docker exec granivpn_nginx tail -n $LINES /var/log/nginx/access.log 2>/dev/null | grep -E '/api|bootstrap|google|send-code' || docker exec granivpn_nginx tail -n 50 /var/log/nginx/access.log 2>/dev/null" || echo "(нет доступа к логам nginx)"
echo ""

echo "--- 2. Nginx access.log (последние 30 строк целиком) ---"
run_remote "docker exec granivpn_nginx tail -n 30 /var/log/nginx/access.log 2>/dev/null" || echo "(нет доступа)"
echo ""

echo "--- 3. Nginx error.log ---"
run_remote "docker exec granivpn_nginx tail -n 50 /var/log/nginx/error.log 2>/dev/null" || echo "(нет доступа)"
echo ""

echo "--- 4. Логи API (gunicorn/uvicorn), последние 150 строк ---"
run_remote "docker logs granivpn_api --tail 150 2>&1" || echo "(контейнер granivpn_api не найден)"
echo ""

echo "--- 5. Контейнеры (статус) ---"
run_remote "cd /opt/grani/server-config/docker 2>/dev/null && docker compose ps 2>/dev/null || docker ps --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null | head -20" || echo "(не удалось)"
echo ""

echo "Готово. Если в access.log нет записей с вашего IP в момент ошибки — запрос до сервера не доходит (таймаут на стороне клиента/сети)."

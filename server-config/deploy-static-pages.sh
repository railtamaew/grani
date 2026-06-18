#!/bin/bash
# Деплой static-pages (политика конфиденциальности) на сервер DigitalOcean
# Запускать с машины, где настроен SSH-ключ к серверу.

set -e
SERVER_IP="${GRANI_SERVER_IP:-159.223.199.122}"
SERVER_USER="${GRANI_SERVER_USER:-root}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "→ Синхронизация static-pages на $SERVER_USER@$SERVER_IP..."
rsync -avz --delete \
  -e "ssh -o StrictHostKeyChecking=no" \
  "$SCRIPT_DIR/static-pages/" \
  "$SERVER_USER@$SERVER_IP:/opt/grani/server-config/static-pages/"

echo "→ Синхронизация nginx.conf и docker-compose..."
rsync -avz -e "ssh -o StrictHostKeyChecking=no" \
  "$SCRIPT_DIR/nginx/nginx.conf" \
  "$SERVER_USER@$SERVER_IP:/opt/grani/server-config/nginx/"
rsync -avz -e "ssh -o StrictHostKeyChecking=no" \
  "$SCRIPT_DIR/docker/docker-compose.yml" \
  "$SERVER_USER@$SERVER_IP:/opt/grani/server-config/docker/"

echo "→ Перезапуск контейнера nginx на сервере..."
ssh -o StrictHostKeyChecking=no "$SERVER_USER@$SERVER_IP" \
  "cd /opt/grani/server-config/docker && docker compose restart nginx"

echo "✅ Готово. Проверьте: https://granilink.com/privacy"

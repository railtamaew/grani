#!/bin/bash
# Развёртывание nginx reverse proxy и certbot на VPN-сервере (45.12.132.94)
#
# Использование:
#   SSH_KEY=~/.ssh/id_rsa SSH_USER=root ./deploy-via-ssh.sh
# или
#   SSH_KEY=~/.ssh/grani_vpn SSH_USER=ubuntu ./deploy-via-ssh.sh
#
# Переменные:
#   SSH_KEY        — путь к приватному ключу (по умолчанию ~/.ssh/id_rsa)
#   SSH_USER       — пользователь SSH (по умолчанию root)
#   SSH_HOST       — хост (по умолчанию 45.12.132.94)
#   CERTBOT_EMAIL  — email для Let's Encrypt (обязательно при первом запуске)

set -e

SSH_HOST="${SSH_HOST:-45.12.132.94}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-admin@granilink.com}"
SSH_USER="${SSH_USER:-root}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_PROXY_CONF="$SCRIPT_DIR/api-proxy.conf"
API_PROXY_HTTP="$SCRIPT_DIR/api-proxy-http-only.conf"

echo "=== Deploy API proxy to $SSH_USER@$SSH_HOST (key: $SSH_KEY) ==="

# Проверка ключа
if [[ ! -f "$SSH_KEY" ]]; then
  echo "Ошибка: SSH ключ не найден: $SSH_KEY"
  echo "Задайте: SSH_KEY=/path/to/key ./deploy-via-ssh.sh"
  exit 1
fi

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

# 1. Проверка nginx
echo ""
echo "[1/5] Проверка nginx на сервере..."
ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "which nginx || (apt-get update -qq && apt-get install -y nginx)"

# 2. Фаза 1 — HTTP-only конфиг (для certbot)
echo ""
echo "[2/5] Копирование HTTP-only конфига (для certbot)..."
scp -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$API_PROXY_HTTP" "$SSH_USER@$SSH_HOST:/tmp/api-proxy.conf"
ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "sudo cp /tmp/api-proxy.conf /etc/nginx/conf.d/api-proxy.conf && sudo nginx -t && sudo systemctl reload nginx"

# 3. Certbot (если ещё не установлен и нет сертификата)
echo ""
echo "[3/5] Получение сертификата Let's Encrypt..."
ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "CERTBOT_EMAIL='$CERTBOT_EMAIL' bash -s" << 'REMOTE'
  if [[ ! -d /etc/letsencrypt/live/api.granilink.com ]]; then
    (which certbot 2>/dev/null) || (apt-get update -qq && apt-get install -y certbot python3-certbot-nginx)
    certbot certonly --nginx -d api.granilink.com --non-interactive --agree-tos --email "${CERTBOT_EMAIL:-admin@granilink.com}"
  else
    echo "Сертификат уже есть."
  fi
REMOTE

# 4. Полный конфиг с SSL
echo ""
echo "[4/5] Копирование полного конфига с SSL..."
scp -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$API_PROXY_CONF" "$SSH_USER@$SSH_HOST:/tmp/api-proxy.conf"
ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "sudo cp /tmp/api-proxy.conf /etc/nginx/conf.d/api-proxy.conf && sudo nginx -t && sudo systemctl reload nginx"

# 5. Проверка
echo ""
echo "[5/5] Проверка..."
ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "curl -s -o /dev/null -w '%{http_code}' https://localhost/api/vpn/bootstrap --resolve api.granilink.com:443:127.0.0.1 -k"
echo ""
echo ""
echo "=== Готово. Проверьте снаружи:"
echo "  curl -s -o /dev/null -w '%{http_code}' https://api.granilink.com/api/vpn/bootstrap"
echo "  curl -s https://api.granilink.com/health"
echo ""

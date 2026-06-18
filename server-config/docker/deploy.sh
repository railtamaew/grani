#!/usr/bin/env bash
# Деплой: build backend + up api, celery, beat, nginx (TLS 80/443 в Docker).
# На хосте systemd nginx должен быть остановлен и disabled, иначе конфликт портов.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
COMPOSE=(docker compose -f server-config/docker/docker-compose.yml)
[[ -f server-config/.env ]] && COMPOSE+=(--env-file server-config/.env)
"${COMPOSE[@]}" build api celery celery_beat
"${COMPOSE[@]}" up -d --no-deps api celery celery_beat nginx
sleep 2
curl -sfS --connect-timeout 8 http://127.0.0.1:8010/health | head -c 200 && echo
# Обновить upstream/DNS в nginx после смены контейнеров API.
"${COMPOSE[@]}" exec -T nginx nginx -t
"${COMPOSE[@]}" exec -T nginx nginx -s reload

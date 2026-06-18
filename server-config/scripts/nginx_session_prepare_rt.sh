#!/usr/bin/env bash
# Выборка rt= (полное время запроса) и urt= (upstream) для session/prepare из access-лога nginx.
# Не читает весь файл: только последние N строк внутри контейнера.
#
# Пример:
#   ./nginx_session_prepare_rt.sh granivpn_nginx 20000

set -euo pipefail
CONTAINER="${1:-granivpn_nginx}"
LINES="${2:-20000}"

docker exec "$CONTAINER" tail -n "$LINES" /var/log/nginx/access.log \
  | grep 'session/prepare' \
  | sed -n 's/.*rt=\([0-9.]*\).*urt=\([0-9.]*\).*/rt=\1 urt=\2/p' \
  | sort -n \
  | awk '
    {gsub(/rt=/,"",$1); gsub(/urt=/,"",$2); r+=$1; u+=$2; n++; if($1>mx)mx=$1}
    END{if(n) printf("n=%d rt_avg=%.4f urt_avg=%.4f rt_max=%.4f\n", n, r/n, u/n, mx); else print "no matches"}'

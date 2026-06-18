#!/bin/bash
# Тестирование API админ-панели с отчётом
# Использование: ./test-admin-api-report.sh [API_BASE_URL]
# API_BASE_URL по умолчанию: https://api.granilink.com (или https://admin.granilink.com для same-origin)

set -e
API_BASE="${1:-https://admin.granilink.com}"
EMAIL="${ADMIN_EMAIL:-rail.tamaew@gmail.com}"
PASS="${ADMIN_PASSWORD:-ChangeThisPassword123!}"
REPORT="/opt/grani/docs/reports/ADMIN_API_TEST_REPORT_$(date +%Y-%m-%d_%H-%M).md"

mkdir -p "$(dirname "$REPORT")"

echo "# Отчёт тестирования API админ-панели" > "$REPORT"
echo "" >> "$REPORT"
echo "**Дата:** $(date -Iseconds)" >> "$REPORT"
echo "**API Base:** $API_BASE" >> "$REPORT"
echo "**Пользователь:** $EMAIL" >> "$REPORT"
echo "" >> "$REPORT"
echo "## Сводка" >> "$REPORT"
echo "" >> "$REPORT"

# Логин
LOGIN_RESP=$(curl -s -w "\n%{http_code}" -X POST "$API_BASE/api/admin/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}")
HTTP_BODY=$(echo "$LOGIN_RESP" | head -n -1)
HTTP_CODE=$(echo "$LOGIN_RESP" | tail -1)
TOKEN=$(echo "$HTTP_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null || echo "")

echo "| Проверка | Результат |" >> "$REPORT"
echo "|----------|-----------|" >> "$REPORT"

if [ "$HTTP_CODE" = "200" ] && [ -n "$TOKEN" ]; then
  echo "| Логин | ✅ OK |" >> "$REPORT"
else
  echo "| Логин | ❌ HTTP $HTTP_CODE |" >> "$REPORT"
  echo "" >> "$REPORT"
  echo "Ошибка логина. Дальнейшие проверки пропущены." >> "$REPORT"
  echo "Отчёт: $REPORT"
  exit 1
fi

# Список эндпоинтов для проверки
ENDPOINTS=(
  "GET:/api/admin/auth/me:Текущий пользователь"
  "GET:/api/admin/dashboard:Дашборд"
  "GET:/api/admin/users?page=1&limit=5:Пользователи"
  "GET:/api/admin/devices?page=1&limit=5:Устройства"
  "GET:/api/admin/trials?page=1&limit=5:Триалы"
  "GET:/api/admin/protocols:Протоколы"
  "GET:/api/admin/servers?page=1&limit=5:Серверы"
  "GET:/api/admin/incidents?page=1&limit=5:Инциденты"
  "GET:/api/admin/payments?page=1&limit=5:Платежи"
  "GET:/api/admin/subscriptions?page=1&limit=5:Подписки"
  "GET:/api/admin/logs/clients?page=1&limit=5:Логи клиента"
  "GET:/api/admin/logs/connections?page=1&limit=5:Логи подключений"
  "GET:/api/admin/audit-log?limit=5:Audit Log"
  "GET:/api/admin/settings:Настройки"
  "GET:/api/admin/settings/admins:Администраторы"
  "GET:/api/admin/stats/auth-providers:Статистика провайдеров"
  "GET:/api/admin/load/alerts?threshold=80:Алерты нагрузки"
  "GET:/api/admin/metrics:Метрики"
  "GET:/api/admin/diagnostics/ping-upstreams:Диагностика"
)

PASSED=0
FAILED=0

for spec in "${ENDPOINTS[@]}"; do
  IFS=':' read -r method path name <<< "$spec"
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$API_BASE$path" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json")
  if [ "$CODE" = "200" ]; then
    echo "| $name | ✅ $CODE |" >> "$REPORT"
    ((PASSED++)) || true
  else
    echo "| $name | ❌ $CODE |" >> "$REPORT"
    ((FAILED++)) || true
  fi
done

echo "" >> "$REPORT"
echo "## Итого" >> "$REPORT"
echo "" >> "$REPORT"
echo "- Пройдено: $PASSED" >> "$REPORT"
echo "- Провалено: $FAILED" >> "$REPORT"
echo "- Всего: $((PASSED+FAILED))" >> "$REPORT"
echo "" >> "$REPORT"

echo "📄 Отчёт сохранён: $REPORT"
cat "$REPORT"

#!/bin/bash
# Запуск всех актуальных тестов.
# Полный план: docs/TEST_PLAN_CURRENT.md

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

echo "🧪 Запуск актуальных тестов"
echo "========================================"
echo ""

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASSED=0
FAILED=0

run_cmd() {
    local test_name="$1"
    shift
    local cmd=("$@")

    echo -e "${YELLOW}📋 Тест: $test_name${NC}"
    echo "----------------------------------------"

    if "${cmd[@]}" 2>&1; then
        echo -e "${GREEN}✅ $test_name: ПРОЙДЕН${NC}"
        ((PASSED++))
        return 0
    else
        echo -e "${RED}❌ $test_name: НЕ ПРОЙДЕН${NC}"
        ((FAILED++))
        return 1
    fi
}

echo "1️⃣  Тестирование протоколов VPN"
echo "========================================"
run_cmd "Протоколы VPN" python3 scripts/test_protocols.py

echo ""
echo "2️⃣  Backend (pytest)"
echo "========================================"
run_cmd "Backend pytest" bash -c "cd backend && python3 -m pytest tests -v --tb=short -q"

echo ""
echo "3️⃣  Admin Panel (lint)"
echo "========================================"
if [ -d admin-panel ] && [ -f admin-panel/package.json ]; then
    run_cmd "Admin lint" bash -c "cd admin-panel && npm run lint"
else
    echo -e "${YELLOW}⏭ admin-panel не найден, пропуск${NC}"
fi

echo ""
echo "========================================"
echo "📊 ИТОГ"
echo "========================================"
echo -e "${GREEN}✅ Пройдено: $PASSED${NC}"
if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED}❌ Не пройдено: $FAILED${NC}"
    echo ""
    echo "Полный план проверок: docs/TEST_PLAN_CURRENT.md"
    exit 1
fi
echo ""
echo "✅ Все тесты пройдены. Mobile: cd mobile-app && flutter test"
exit 0

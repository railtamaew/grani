# План проверок по актуальным сценариям

Устаревшие проверки (singbox, device_id) отключены. Ниже только существующие и актуальные сценарии.

---

## 1. Backend (Python/FastAPI)

| Что | Команда | Примечание |
|-----|---------|------------|
| Все unit/integration тесты | `cd backend && python3 -m pytest -v` | SQLite in-memory, Redis не обязателен (тесты с Redis скипаются при недоступности) |
| С покрытием | `cd backend && python3 -m pytest --cov=. --cov-report=term-missing` | |
| Только быстрые | `cd backend && python3 -m pytest -m "not slow"` | |

**Зависимости:** `pip install -r backend/requirements.txt backend/requirements-test.txt`

**Где тесты:** `backend/tests/` (pytest, 31 файл: auth, VPN API, admin API, протоколы, кэш, rate limit и т.д.)

---

## 2. Скрипты в корне (протоколы)

| Что | Команда |
|-----|---------|
| Тесты протоколов VPN | `python3 scripts/test_all.py` |
| Только протоколы (то же) | `python3 scripts/test_protocols.py` |
| Shell-обёртка | `./scripts/RUN_ALL_TESTS.sh` |

Singbox и device_id из точек входа убраны.

---

## 3. Admin Panel (React/TypeScript)

| Что | Команда | Примечание |
|-----|---------|------------|
| Линт | `cd admin-panel && npm run lint` | ESLint по src |
| Unit-тесты | `cd admin-panel && npm test` | Jest (react-scripts) |
| E2E | `cd admin-panel && npm run test:e2e` | Playwright; нужны backend, ADMIN_EMAIL, ADMIN_PASSWORD |

---

## 4. Mobile App (Flutter)

| Что | Команда |
|-----|---------|
| Все тесты | `cd mobile-app && flutter test` |

Тесты в `mobile-app/test/` (unit, integration, protocols/xray).

---

## 5. Рекомендуемый порядок

1. **Backend:** `cd backend && python3 -m pytest -v`
2. **Протоколы:** `python3 scripts/test_all.py`
3. **Admin:** `cd admin-panel && npm run lint && npm test`
4. **Mobile:** `cd mobile-app && flutter test`
5. **E2E админки** (по желанию, при поднятом backend и env): `cd admin-panel && npm run test:e2e`

---

## 6. Что отключено (устарело)

- **singbox** — тесты конфигов sing-box и вызов бинарника sing-box убраны из `test_all.py`, `RUN_ALL_TESTS.sh`, `execute_tests.py`.
- **device_id** — отдельные тесты механизма device_id убраны из тех же скриптов.

Скрипты `scripts/test_singbox_config.py` и `scripts/test_device_id.py` в репозитории остаются, но в общий прогон не входят.

# 🧹 ПЛАН ОЧИСТКИ ПРОЕКТА

**Дата:** 2026-01-14  
**Статус:** ✅ Завершено

## ⚠️ ВАЖНО
- **НЕ ТРОГАЕМ:** `backend/api/auth.py`, `backend/services/auth_service.py`, `backend/services/email_service.py`
- **НЕ ТРОГАЕМ:** `backend/core/config.py` (секреты)
- **НЕ ТРОГАЕМ:** Логику авторизации и email

---

## ✅ SAFE TO DELETE (Безопасно удалить)

### Mobile App - Неиспользуемые экраны:
- ✅ `mobile-app/lib/screens/trial_start_screen.dart` - УДАЛЕН
- ✅ `mobile-app/lib/screens/vpn_disconnected_trial_screen.dart` - УДАЛЕН
- ✅ `mobile-app/lib/screens/vpn_connecting_trial_screen.dart` - УДАЛЕН
- ✅ `mobile-app/lib/screens/vpn_connected_trial_screen.dart` - УДАЛЕН
- ✅ `mobile-app/lib/screens/vpn_trial_screen.dart` - УДАЛЕН

**Статус проверки:** Все маршруты `/trial-start`, `/vpn-disconnected-trial`, `/vpn-connecting-trial`, `/vpn-connected-trial` ведут на `TrialUnifiedScreen`.

### Backend - Тестовые файлы (не используются в проде):
- ✅ `backend/test_*.py` (15 файлов) - УДАЛЕНЫ

**Статус проверки:** Эти файлы не импортируются в основном коде.

---

## ⚠️ RISKY (Требует проверки)

### Backend Scripts:
- Многие скрипты в `backend/scripts/` могут быть временными
- **Рекомендация:** Пока не трогать, возможно используются для диагностики

---

## 📝 ВЫПОЛНЕНО

1. ✅ Создан детальный отчет анализа (`docs/PROJECT_ANALYSIS_REPORT.md`)
2. ✅ Удален неиспользуемый импорт `trial_start_screen.dart` из `main.dart`
3. ✅ Проверка компиляции - успешно, ошибок нет
4. ✅ Удалены неиспользуемые экраны (5 файлов):
   - `trial_start_screen.dart`
   - `vpn_disconnected_trial_screen.dart`
   - `vpn_connecting_trial_screen.dart`
   - `vpn_connected_trial_screen.dart`
   - `vpn_trial_screen.dart`
5. ✅ Удалены тестовые файлы (15 файлов):
   - `test_create_server.py`
   - `test_code_save.py`
   - `test_mobile_app_request.py`
   - `test_api_email.py`
   - `test_email_sesv2.py`
   - `test_both_api_approaches.py`
   - `test_both_approaches.py`
   - `test_yandex_postbox_v2.py`
   - `test_endpoint_variants.py`
   - `test_postbox_connection.py`
   - `test_api_formats.py`
   - `test_postbox_simple.py`
   - `test_real_send.py`
   - `test_email_direct.py`
   - `test_email_send.py`

---

## ✅ РЕЗУЛЬТАТ

- **Удалено экранов:** 5
- **Удалено тестовых файлов:** 15
- **Компиляция:** ✅ Успешно, ошибок нет
- **Статус:** Все задачи плана выполнены

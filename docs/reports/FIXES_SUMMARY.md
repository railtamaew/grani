# Сводка исправлений - 10 декабря 2024

## ✅ Исправления в мобильном приложении

### 1. Логотип на всех экранах
- **Проблема**: Логотип пропадал или был неправильно позиционирован
- **Исправление**: Убран `const` из всех вызовов `AuthLogo()` в следующих файлах:
  - `start_screen.dart`
  - `auth_email_screen.dart`
  - `auth_code_screen.dart`
  - `vpn_connecting_trial_screen.dart`
  - `vpn_disconnected_trial_screen.dart`
  - `trial_start_screen.dart`
  - `vpn_connected_trial_screen.dart`
  - `trial_ended_screen.dart`
  - `subscription_activated_screen.dart`

### 2. Белый экран на экране ввода PIN-кода
- **Проблема**: После ввода email появлялся белый экран
- **Исправление**: 
  - Упрощен `build` метод в `auth_code_screen.dart`
  - Убраны лишние проверки размеров экрана
  - Исправлена инициализация `_dailyRemaining` через `WidgetsBinding.instance.addPostFrameCallback`
  - Убраны лишние `LayoutBuilder` обертки

### 3. Белый экран на экране ввода email
- **Проблема**: Белый экран при переходе на экран ввода email
- **Исправление**: 
  - Упрощен доступ к `AuthService` через `Consumer` и `Provider.of`
  - Убраны лишние `try-catch` блоки
  - Исправлена обработка состояний загрузки

## ✅ Исправления в backend (Email авторизация)

### 1. Формат запроса к Yandex Cloud Postbox
- **Проблема**: Письма не приходили из-за неправильного формата запроса
- **Исправление**: 
  - Используется **только** `sesv2` client для Yandex Postbox
  - Формат запроса: `FromEmailAddress` + `Content` (Simple)
  - Удалены все fallback на SMTP
  - Удалены все использования старого `ses` client с `Source` и `Message`

### 2. Файлы с исправлениями:
- `/opt/grani/backend/services/aws_ses_service.py`:
  - Определение Yandex Postbox по endpoint `postbox.cloud.yandex.net`
  - Использование `sesv2` client с правильным форматом
  - Обработка `ResponseParserError` для текстовых ответов Yandex
  
- `/opt/grani/backend/api/auth.py`:
  - Все вызовы используют только `send_verification_email_ses`
  - Удалены все ссылки на SMTP
  - `db.commit()` вызывается перед отправкой email
  - Email отправляется через `BackgroundTasks` (не блокирует API)

### 3. Проверка работы:
```bash
# Тест отправки email
curl -X POST http://159.223.199.122:8000/api/auth/send-code \
  -H "Content-Type: application/json" \
  -d '{"email": "rail.tamaew@gmail.com"}'

# Ожидаемый ответ: {"ok":true}
```

## ⚠️ Известные проблемы

### Email не приходит
- **Статус**: Сервер возвращает `{"ok":true}`, MessageId получен
- **Возможные причины**:
  1. Письма попадают в спам (проверьте папку "Спам")
  2. Yandex Postbox требует верификации отправителя `support@granilink.com`
  3. Задержка доставки (может быть до 5-10 минут)

### Проверка верификации отправителя:
1. Зайдите в Yandex Cloud Console
2. Перейдите в Postbox
3. Проверьте статус верификации email `support@granilink.com`
4. Если не верифицирован - выполните верификацию

## 📦 Сборка APK

### Команды для сборки:
```bash
cd /opt/grani/mobile-app
flutter clean
flutter pub get
flutter build apk --debug
```

### Результат:
- APK: `/opt/grani/mobile-app/build/app/outputs/flutter-apk/app-debug.apk`
- Копия: `/opt/grani/granivpn-debug.apk`
- Размер: ~150 MB
- Ссылка: `http://159.223.199.122:8001/granivpn-debug.apk`

## 🔍 Что проверить после установки APK

1. ✅ Логотип отображается на всех экранах
2. ✅ Нет белого экрана при переходе на ввод email
3. ✅ Нет белого экрана при переходе на ввод PIN-кода
4. ⚠️ Email приходит (проверьте спам, верификацию отправителя)
5. ✅ Ошибки Google авторизации не показываются пользователю (только в логах)

## 📝 Следующие шаги

1. Проверить верификацию отправителя в Yandex Cloud Postbox
2. Проверить папку "Спам" для тестовых писем
3. Если письма все еще не приходят - проверить логи сервера:
   ```bash
   tail -f /tmp/uvicorn.log | grep -i email
   ```




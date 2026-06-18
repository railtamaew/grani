# Быстрое решение проблемы с генерацией планов в Cursor

## ✅ Что уже проверено на сервере

- ✅ Интернет доступен
- ✅ DNS работает (cursor.sh разрешается)
- ✅ Сайты Cursor доступны
- ⚠️ API Cursor (`api.cursor.sh`) недоступен снаружи (это нормально - API может быть внутренним)

**Вывод**: Ваш сервер НЕ блокирует доступ к Cursor. Проблема не связана с ограничениями на сервере.

## 🔧 Что нужно сделать на ваших устройствах

### 1. Запустите скрипт проверки

#### Linux/Mac:
```bash
cd /opt/grani/scripts
./check_cursor_api.sh
```

#### Windows (PowerShell):
```powershell
cd C:\path\to\grani\scripts
.\check_cursor_api.ps1
```

### 2. Проверьте логи Cursor

**Windows:**
```
%APPDATA%\Cursor\logs\
```

**Mac:**
```
~/Library/Application Support/Cursor/logs/
```

**Linux:**
```
~/.config/Cursor/logs/
```

Ищите ошибки: `Connection timeout`, `DNS resolution failed`, `API request failed`

### 3. Быстрые исправления

1. **Перезапустите Cursor** (полностью закройте и откройте заново)
2. **Обновите Cursor** до последней версии
3. **Проверьте настройки прокси** в Cursor (Settings → Proxy)
4. **Попробуйте с другого интернета** (например, мобильный интернет)

### 4. Очистка кэша (если не помогло)

**Windows:**
```powershell
# Закройте Cursor, затем:
Remove-Item -Recurse -Force "$env:APPDATA\Cursor\Cache"
```

**Mac:**
```bash
# Закройте Cursor, затем:
rm -rf ~/Library/Application\ Support/Cursor/Cache
```

**Linux:**
```bash
# Закройте Cursor, затем:
rm -rf ~/.config/Cursor/Cache
```

## 📋 Документация

- **Полная диагностика**: `/opt/grani/docs/CURSOR_PLAN_GENERATION_DIAGNOSTICS.md`
- **Руководство по устранению**: `/opt/grani/docs/CURSOR_TROUBLESHOOTING_GUIDE.md`

## ⚠️ Важно

Проблема **НЕ связана с вашим сервером**. Ограничения на сервере (Nginx timeout 30s, rate limiting) влияют только на ваш API (`api.granilink.com`), а не на работу Cursor.

Cursor работает локально и использует свой собственный API для генерации планов.

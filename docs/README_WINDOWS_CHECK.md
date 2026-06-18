# Инструкция: Проверка Cursor на Windows

## 🚀 Быстрый способ (рекомендуется)

### Вариант 1: Одна команда

Откройте PowerShell и выполните:

```powershell
Write-Host "`n=== Проверка Cursor ===" -ForegroundColor Cyan; Write-Host "1. Интернет..." -NoNewline; if (Test-Connection 8.8.8.8 -Count 1 -Quiet) { Write-Host " ✓ OK" -ForegroundColor Green } else { Write-Host " ✗ НЕТ" -ForegroundColor Red }; Write-Host "2. DNS..." -NoNewline; try { $dns = Resolve-DnsName cursor.sh -ErrorAction Stop; Write-Host " ✓ OK (IP: $($dns[0].IPAddress))" -ForegroundColor Green } catch { Write-Host " ✗ ОШИБКА" -ForegroundColor Red }; Write-Host "3. Сайт cursor.sh..." -NoNewline; try { Invoke-WebRequest -Uri "https://www.cursor.sh" -Method Head -TimeoutSec 5 -UseBasicParsing | Out-Null; Write-Host " ✓ Доступен" -ForegroundColor Green } catch { Write-Host " ✗ Недоступен" -ForegroundColor Red }; Write-Host "4. Прокси..." -NoNewline; if ($env:HTTP_PROXY -or $env:HTTPS_PROXY) { Write-Host " ⚠ Настроен" -ForegroundColor Yellow } else { Write-Host " ✓ Не настроен" -ForegroundColor Green }; Write-Host "5. Cursor..." -NoNewline; if (Test-Path "$env:APPDATA\Cursor") { Write-Host " ✓ Установлен" -ForegroundColor Green } else { Write-Host " ⚠ Не найден" -ForegroundColor Yellow }; Write-Host "`n=== Готово ===" -ForegroundColor Cyan
```

### Вариант 2: Скрипт

1. Откройте файл: `/opt/grani/scripts/check_cursor_windows_simple.ps1`
2. Скопируйте всё содержимое
3. Вставьте в PowerShell и нажмите Enter

## 📋 Что проверяется

1. ✅ **Интернет** - доступность базового интернет-соединения
2. ✅ **DNS** - разрешение домена cursor.sh
3. ✅ **Сайт Cursor** - доступность сайта cursor.sh
4. ✅ **Прокси** - наличие настроек прокси
5. ✅ **Установка Cursor** - наличие Cursor на компьютере

## 🔍 Детальная проверка

Для более детальной проверки используйте полный скрипт:

1. Откройте файл: `/opt/grani/scripts/check_cursor_windows.ps1`
2. Скопируйте всё содержимое
3. Вставьте в PowerShell и нажмите Enter

Полный скрипт также проверяет:
- Порты (443, 80)
- Настройки прокси в реестре Windows
- Версию Cursor
- Логи Cursor

## 📁 Файлы

- **Простой скрипт**: `/opt/grani/scripts/check_cursor_windows_simple.ps1`
- **Полный скрипт**: `/opt/grani/scripts/check_cursor_windows.ps1`
- **Инструкции**: `/opt/grani/docs/WINDOWS_CHECK_INSTRUCTIONS.md`

## ⚠️ Если скрипт не запускается

Если PowerShell блокирует выполнение скрипта, выполните:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

Затем попробуйте снова.

## 📊 Что делать после проверки

### Если все проверки прошли успешно:
1. Проверьте логи Cursor: `%APPDATA%\Cursor\logs\`
2. Перезапустите Cursor
3. Обновите Cursor до последней версии
4. Очистите кэш Cursor (см. ниже)

### Если обнаружены проблемы:
1. Проверьте настройки прокси/firewall
2. Попробуйте с другого интернет-соединения
3. Обратитесь к IT-отделу (если в корпоративной сети)

## 🧹 Очистка кэша Cursor

```powershell
# Закройте Cursor полностью, затем:
Remove-Item -Recurse -Force "$env:APPDATA\Cursor\Cache" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "$env:APPDATA\Cursor\Code Cache" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "$env:APPDATA\Cursor\GPUCache" -ErrorAction SilentlyContinue
Write-Host "Кэш очищен. Перезапустите Cursor." -ForegroundColor Green
```

## 📝 Проверка логов Cursor

```powershell
# Открыть папку с логами
explorer "$env:APPDATA\Cursor\logs"

# Или посмотреть последние логи в консоли
Get-ChildItem "$env:APPDATA\Cursor\logs\*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 3 | ForEach-Object { Write-Host "`n=== $($_.Name) ===" -ForegroundColor Cyan; Get-Content $_.FullName -Tail 15 }
```

---

**Важно**: Проблема НЕ связана с вашим сервером. Ограничения на сервере влияют только на ваш API, а не на работу Cursor.

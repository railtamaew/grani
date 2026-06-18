# Инструкция по проверке Cursor на Windows

## Способ 1: Выполнить скрипт напрямую в PowerShell

### Шаг 1: Откройте PowerShell
- Нажмите `Win + X` и выберите "Windows PowerShell" или "Terminal"
- Или найдите "PowerShell" в меню Пуск

### Шаг 2: Скопируйте и выполните команду

Скопируйте весь скрипт из файла `/opt/grani/scripts/check_cursor_windows.ps1` и вставьте в PowerShell, затем нажмите Enter.

**Или выполните команду напрямую:**

```powershell
# Если скрипт находится на сервере, скопируйте его содержимое и выполните
# Или используйте эту упрощенную версию:

Write-Host "=== Проверка доступности API Cursor ===" -ForegroundColor Cyan

# Проверка интернета
Write-Host "1. Проверка интернета..." -ForegroundColor Yellow
$ping = Test-Connection -ComputerName 8.8.8.8 -Count 2 -Quiet
if ($ping) {
    Write-Host "   ✓ Интернет доступен" -ForegroundColor Green
} else {
    Write-Host "   ✗ Нет интернета" -ForegroundColor Red
}

# Проверка DNS
Write-Host "2. Проверка DNS..." -ForegroundColor Yellow
try {
    $dns = Resolve-DnsName -Name "cursor.sh" -ErrorAction Stop
    Write-Host "   ✓ cursor.sh разрешается (IP: $($dns[0].IPAddress))" -ForegroundColor Green
} catch {
    Write-Host "   ✗ cursor.sh не разрешается" -ForegroundColor Red
}

# Проверка доступности сайтов
Write-Host "3. Проверка доступности сайтов..." -ForegroundColor Yellow
try {
    $response = Invoke-WebRequest -Uri "https://www.cursor.sh" -Method Head -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
    Write-Host "   ✓ www.cursor.sh доступен" -ForegroundColor Green
} catch {
    Write-Host "   ✗ www.cursor.sh недоступен" -ForegroundColor Red
}

# Проверка прокси
Write-Host "4. Проверка прокси..." -ForegroundColor Yellow
if ($env:HTTP_PROXY -or $env:HTTPS_PROXY) {
    Write-Host "   ⚠ Прокси настроен" -ForegroundColor Yellow
    Write-Host "      HTTP_PROXY: $env:HTTP_PROXY" -ForegroundColor Yellow
    Write-Host "      HTTPS_PROXY: $env:HTTPS_PROXY" -ForegroundColor Yellow
} else {
    Write-Host "   ✓ Прокси не настроен" -ForegroundColor Green
}

# Проверка Cursor
Write-Host "5. Проверка установки Cursor..." -ForegroundColor Yellow
$cursorPath = "$env:APPDATA\Cursor"
if (Test-Path $cursorPath) {
    Write-Host "   ✓ Cursor найден: $cursorPath" -ForegroundColor Green
} else {
    Write-Host "   ⚠ Cursor не найден" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Проверка завершена ===" -ForegroundColor Cyan
```

## Способ 2: Сохранить и выполнить скрипт

### Шаг 1: Создайте файл скрипта

1. Откройте Блокнот
2. Скопируйте содержимое из `/opt/grani/scripts/check_cursor_windows.ps1`
3. Сохраните как `check_cursor.ps1` (например, на Рабочий стол)

### Шаг 2: Выполните скрипт

Откройте PowerShell и выполните:

```powershell
# Перейдите в папку со скриптом
cd C:\Users\YourName\Desktop

# Разрешите выполнение скрипта (если нужно)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Запустите скрипт
.\check_cursor.ps1
```

## Способ 3: Быстрая проверка (одна команда)

Выполните эту команду в PowerShell для быстрой проверки:

```powershell
Write-Host "Проверка Cursor..." -ForegroundColor Cyan; Test-Connection 8.8.8.8 -Count 1 -Quiet | ForEach-Object { if ($_) { Write-Host "✓ Интернет OK" -ForegroundColor Green } else { Write-Host "✗ Нет интернета" -ForegroundColor Red } }; try { $dns = Resolve-DnsName cursor.sh -ErrorAction Stop; Write-Host "✓ DNS OK (IP: $($dns[0].IPAddress))" -ForegroundColor Green } catch { Write-Host "✗ DNS ошибка" -ForegroundColor Red }; try { Invoke-WebRequest -Uri "https://www.cursor.sh" -Method Head -TimeoutSec 5 -UseBasicParsing | Out-Null; Write-Host "✓ Cursor доступен" -ForegroundColor Green } catch { Write-Host "✗ Cursor недоступен" -ForegroundColor Red }
```

## Что делать после проверки

### Если все проверки прошли успешно:
1. Проверьте логи Cursor: `%APPDATA%\Cursor\logs\`
2. Перезапустите Cursor
3. Обновите Cursor до последней версии
4. Очистите кэш Cursor:
   ```powershell
   Remove-Item -Recurse -Force "$env:APPDATA\Cursor\Cache"
   ```

### Если обнаружены проблемы:
1. Проверьте настройки прокси/firewall
2. Попробуйте с другого интернет-соединения
3. Обратитесь к IT-отделу (если в корпоративной сети)

## Проверка логов Cursor

```powershell
# Открыть папку с логами
explorer "$env:APPDATA\Cursor\logs"

# Или посмотреть последние логи
Get-ChildItem "$env:APPDATA\Cursor\logs\*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 5 | ForEach-Object { Write-Host "`n=== $($_.Name) ===" -ForegroundColor Cyan; Get-Content $_.FullName -Tail 20 }
```

## Очистка кэша Cursor

```powershell
# Закройте Cursor полностью, затем:
Write-Host "Очистка кэша Cursor..." -ForegroundColor Yellow

$cachePaths = @(
    "$env:APPDATA\Cursor\Cache",
    "$env:APPDATA\Cursor\Code Cache",
    "$env:APPDATA\Cursor\GPUCache"
)

foreach ($path in $cachePaths) {
    if (Test-Path $path) {
        Remove-Item -Recurse -Force $path -ErrorAction SilentlyContinue
        Write-Host "✓ Очищен: $path" -ForegroundColor Green
    }
}

Write-Host "`nГотово! Перезапустите Cursor." -ForegroundColor Green
```

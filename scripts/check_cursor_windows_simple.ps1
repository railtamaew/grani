# Быстрая проверка Cursor на Windows - скопируйте и выполните в PowerShell

Write-Host "`n=== Проверка доступности API Cursor ===" -ForegroundColor Cyan
Write-Host ""

# 1. Интернет
Write-Host "1. Интернет..." -NoNewline
if (Test-Connection 8.8.8.8 -Count 1 -Quiet) {
    Write-Host " ✓ OK" -ForegroundColor Green
} else {
    Write-Host " ✗ НЕТ" -ForegroundColor Red
    exit
}

# 2. DNS
Write-Host "2. DNS cursor.sh..." -NoNewline
try {
    $dns = Resolve-DnsName cursor.sh -ErrorAction Stop
    Write-Host " ✓ OK (IP: $($dns[0].IPAddress))" -ForegroundColor Green
} catch {
    Write-Host " ✗ ОШИБКА" -ForegroundColor Red
}

# 3. Сайт Cursor
Write-Host "3. Сайт cursor.sh..." -NoNewline
try {
    Invoke-WebRequest -Uri "https://www.cursor.sh" -Method Head -TimeoutSec 5 -UseBasicParsing | Out-Null
    Write-Host " ✓ Доступен" -ForegroundColor Green
} catch {
    Write-Host " ✗ Недоступен" -ForegroundColor Red
}

# 4. Прокси
Write-Host "4. Прокси..." -NoNewline
if ($env:HTTP_PROXY -or $env:HTTPS_PROXY) {
    Write-Host " ⚠ Настроен" -ForegroundColor Yellow
} else {
    Write-Host " ✓ Не настроен" -ForegroundColor Green
}

# 5. Cursor установлен
Write-Host "5. Cursor установлен..." -NoNewline
if (Test-Path "$env:APPDATA\Cursor") {
    Write-Host " ✓ Да" -ForegroundColor Green
} else {
    Write-Host " ⚠ Не найден" -ForegroundColor Yellow
}

Write-Host "`n=== Готово ===" -ForegroundColor Cyan
Write-Host "Если проблемы остаются, проверьте логи: $env:APPDATA\Cursor\logs\" -ForegroundColor Yellow
Write-Host ""

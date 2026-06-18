# PowerShell скрипт для проверки доступности API Cursor (Windows)
# Использование: .\check_cursor_api.ps1

Write-Host "=== Проверка доступности API Cursor ===" -ForegroundColor Cyan
Write-Host ""

# Функция проверки доступности
function Test-Url {
    param(
        [string]$Url,
        [string]$Name
    )
    
    Write-Host -NoNewline "Проверка $Name ($Url)... "
    
    try {
        $response = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        Write-Host "✓ Доступен" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "✗ Недоступен" -ForegroundColor Red
        return $false
    }
}

# Функция проверки DNS
function Test-DnsResolution {
    param(
        [string]$Hostname
    )
    
    Write-Host -NoNewline "DNS разрешение для $Hostname... "
    
    try {
        $result = Resolve-DnsName -Name $Hostname -ErrorAction Stop
        Write-Host "✓ Разрешается" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "✗ Не разрешается" -ForegroundColor Red
        return $false
    }
}

# Проверка базового интернета
Write-Host "1. Проверка базового интернет-соединения:" -ForegroundColor Yellow
try {
    $ping = Test-Connection -ComputerName 8.8.8.8 -Count 2 -Quiet
    if ($ping) {
        Write-Host "   ✓ Интернет доступен" -ForegroundColor Green
    }
    else {
        Write-Host "   ✗ Нет интернет-соединения" -ForegroundColor Red
        exit 1
    }
}
catch {
    Write-Host "   ✗ Ошибка проверки интернета" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Проверка DNS
Write-Host "2. Проверка DNS:" -ForegroundColor Yellow
Test-DnsResolution "cursor.sh"
Test-DnsResolution "api.cursor.sh"
Test-DnsResolution "www.cursor.sh"

Write-Host ""

# Проверка доступности сайтов
Write-Host "3. Проверка доступности сайтов Cursor:" -ForegroundColor Yellow
Test-Url "https://www.cursor.sh" "Cursor главная"
Test-Url "https://cursor.sh" "Cursor (без www)"
Test-Url "https://api.cursor.sh" "Cursor API"

Write-Host ""

# Проверка портов
Write-Host "4. Проверка портов:" -ForegroundColor Yellow
$ports = @(443, 80)
foreach ($port in $ports) {
    Write-Host -NoNewline "   Порт $port... "
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $connect = $tcpClient.BeginConnect("cursor.sh", $port, $null, $null)
        $wait = $connect.AsyncWaitHandle.WaitOne(3000, $false)
        if ($wait) {
            $tcpClient.EndConnect($connect)
            Write-Host "✓ Открыт" -ForegroundColor Green
            $tcpClient.Close()
        }
        else {
            Write-Host "✗ Таймаут" -ForegroundColor Red
            $tcpClient.Close()
        }
    }
    catch {
        Write-Host "✗ Закрыт или недоступен" -ForegroundColor Red
    }
}

Write-Host ""

# Проверка прокси
Write-Host "5. Проверка настроек прокси:" -ForegroundColor Yellow
$httpProxy = $env:HTTP_PROXY
$httpsProxy = $env:HTTPS_PROXY

if ($httpProxy -or $httpsProxy) {
    Write-Host "   ⚠ Прокси настроен:" -ForegroundColor Yellow
    if ($httpProxy) { Write-Host "      HTTP_PROXY=$httpProxy" }
    if ($httpsProxy) { Write-Host "      HTTPS_PROXY=$httpsProxy" }
}
else {
    Write-Host "   ✓ Прокси не настроен" -ForegroundColor Green
}

# Проверка прокси в реестре Windows
try {
    $regProxy = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue
    if ($regProxy.ProxyEnable -eq 1) {
        Write-Host "   ⚠ Прокси включен в настройках Windows:" -ForegroundColor Yellow
        Write-Host "      ProxyServer: $($regProxy.ProxyServer)" -ForegroundColor Yellow
    }
}
catch {
    # Игнорируем ошибки чтения реестра
}

Write-Host ""

# Итоговая сводка
Write-Host "=== Итоговая сводка ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Если все проверки прошли успешно, но Cursor все равно не работает:" -ForegroundColor Yellow
Write-Host "1. Проверьте логи Cursor: %APPDATA%\Cursor\logs\" -ForegroundColor White
Write-Host "2. Проверьте настройки прокси в Cursor (Settings → Proxy)" -ForegroundColor White
Write-Host "3. Попробуйте перезапустить Cursor" -ForegroundColor White
Write-Host "4. Проверьте версию Cursor (обновите до последней)" -ForegroundColor White
Write-Host "5. Попробуйте с другого интернет-соединения" -ForegroundColor White
Write-Host ""

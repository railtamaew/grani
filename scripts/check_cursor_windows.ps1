# PowerShell скрипт для проверки доступности API Cursor (Windows)
# Использование: Скопируйте весь скрипт и выполните в PowerShell

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
        Write-Host "✗ Недоступен: $($_.Exception.Message)" -ForegroundColor Red
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
        Write-Host "✓ Разрешается (IP: $($result[0].IPAddress))" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "✗ Не разрешается: $($_.Exception.Message)" -ForegroundColor Red
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
    Write-Host "   ✗ Ошибка проверки интернета: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Проверка DNS
Write-Host "2. Проверка DNS:" -ForegroundColor Yellow
$dnsResults = @()
$dnsResults += Test-DnsResolution "cursor.sh"
$dnsResults += Test-DnsResolution "api.cursor.sh"
$dnsResults += Test-DnsResolution "www.cursor.sh"

Write-Host ""

# Проверка доступности сайтов
Write-Host "3. Проверка доступности сайтов Cursor:" -ForegroundColor Yellow
$urlResults = @()
$urlResults += Test-Url "https://www.cursor.sh" "Cursor главная"
$urlResults += Test-Url "https://cursor.sh" "Cursor (без www)"
$urlResults += Test-Url "https://api.cursor.sh" "Cursor API"

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
        Write-Host "✗ Закрыт или недоступен: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""

# Проверка прокси
Write-Host "5. Проверка настроек прокси:" -ForegroundColor Yellow
$httpProxy = $env:HTTP_PROXY
$httpsProxy = $env:HTTPS_PROXY

if ($httpProxy -or $httpsProxy) {
    Write-Host "   ⚠ Прокси настроен в переменных окружения:" -ForegroundColor Yellow
    if ($httpProxy) { Write-Host "      HTTP_PROXY=$httpProxy" -ForegroundColor Yellow }
    if ($httpsProxy) { Write-Host "      HTTPS_PROXY=$httpsProxy" -ForegroundColor Yellow }
}
else {
    Write-Host "   ✓ Прокси не настроен в переменных окружения" -ForegroundColor Green
}

# Проверка прокси в реестре Windows
try {
    $regProxy = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue
    if ($regProxy.ProxyEnable -eq 1) {
        Write-Host "   ⚠ Прокси включен в настройках Windows:" -ForegroundColor Yellow
        Write-Host "      ProxyServer: $($regProxy.ProxyServer)" -ForegroundColor Yellow
        Write-Host "      ProxyOverride: $($regProxy.ProxyOverride)" -ForegroundColor Yellow
    }
    else {
        Write-Host "   ✓ Прокси не включен в настройках Windows" -ForegroundColor Green
    }
}
catch {
    Write-Host "   ⚠ Не удалось проверить настройки прокси в реестре" -ForegroundColor Yellow
}

Write-Host ""

# Проверка версии Cursor (если установлен)
Write-Host "6. Проверка установки Cursor:" -ForegroundColor Yellow
$cursorPaths = @(
    "$env:APPDATA\Cursor",
    "$env:LOCALAPPDATA\Programs\cursor",
    "${env:ProgramFiles}\Cursor"
)

$cursorFound = $false
foreach ($path in $cursorPaths) {
    if (Test-Path $path) {
        Write-Host "   ✓ Cursor найден: $path" -ForegroundColor Green
        $cursorFound = $true
        
        # Попытка найти версию
        $versionFile = Join-Path $path "resources\app\package.json"
        if (Test-Path $versionFile) {
            try {
                $package = Get-Content $versionFile | ConvertFrom-Json
                Write-Host "      Версия: $($package.version)" -ForegroundColor Cyan
            }
            catch {
                # Игнорируем ошибки чтения версии
            }
        }
    }
}

if (-not $cursorFound) {
    Write-Host "   ⚠ Cursor не найден в стандартных местах" -ForegroundColor Yellow
}

Write-Host ""

# Проверка логов Cursor
Write-Host "7. Проверка логов Cursor:" -ForegroundColor Yellow
$logPath = "$env:APPDATA\Cursor\logs"
if (Test-Path $logPath) {
    Write-Host "   ✓ Папка логов найдена: $logPath" -ForegroundColor Green
    
    $logFiles = Get-ChildItem -Path $logPath -Filter "*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 5
    if ($logFiles) {
        Write-Host "   Последние файлы логов:" -ForegroundColor Cyan
        foreach ($logFile in $logFiles) {
            Write-Host "      - $($logFile.Name) ($(Get-Date $logFile.LastWriteTime -Format 'yyyy-MM-dd HH:mm:ss'))" -ForegroundColor White
        }
    }
    else {
        Write-Host "   ⚠ Файлы логов не найдены" -ForegroundColor Yellow
    }
}
else {
    Write-Host "   ⚠ Папка логов не найдена: $logPath" -ForegroundColor Yellow
}

Write-Host ""

# Итоговая сводка
Write-Host "=== Итоговая сводка ===" -ForegroundColor Cyan
Write-Host ""

$allDnsOk = $dnsResults -notcontains $false
$allUrlsOk = $urlResults -notcontains $false

if ($allDnsOk -and $allUrlsOk) {
    Write-Host "✓ Все базовые проверки прошли успешно" -ForegroundColor Green
    Write-Host ""
    Write-Host "Если Cursor все равно не работает:" -ForegroundColor Yellow
    Write-Host "1. Проверьте логи Cursor: $env:APPDATA\Cursor\logs\" -ForegroundColor White
    Write-Host "2. Проверьте настройки прокси в Cursor (Settings → Proxy)" -ForegroundColor White
    Write-Host "3. Попробуйте перезапустить Cursor" -ForegroundColor White
    Write-Host "4. Проверьте версию Cursor (обновите до последней)" -ForegroundColor White
    Write-Host "5. Попробуйте с другого интернет-соединения" -ForegroundColor White
    Write-Host "6. Очистите кэш Cursor:" -ForegroundColor White
    Write-Host "   Remove-Item -Recurse -Force `"$env:APPDATA\Cursor\Cache`"" -ForegroundColor Gray
}
else {
    Write-Host "⚠ Обнаружены проблемы с доступностью:" -ForegroundColor Yellow
    if (-not $allDnsOk) {
        Write-Host "   - Проблемы с DNS разрешением" -ForegroundColor Red
    }
    if (-not $allUrlsOk) {
        Write-Host "   - Проблемы с доступностью сайтов Cursor" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "Рекомендации:" -ForegroundColor Yellow
    Write-Host "1. Проверьте настройки прокси/firewall" -ForegroundColor White
    Write-Host "2. Проверьте корпоративные ограничения сети" -ForegroundColor White
    Write-Host "3. Попробуйте с другого интернет-соединения" -ForegroundColor White
    Write-Host "4. Обратитесь к IT-отделу для проверки логов firewall" -ForegroundColor White
}

Write-Host ""

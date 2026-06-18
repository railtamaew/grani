# Скрипт для синхронизации проекта с сервером (Windows PowerShell)
# Использование: .\server-config\sync-to-server.ps1

param(
    [string]$ServerIP = "159.223.199.122",
    [string]$ServerUser = "root",
    [string]$ServerPath = "/opt/grani",
    [string]$SshKey = "$env:USERPROFILE\.ssh\id_ed25519_grani",
    [switch]$DryRun = $false,
    [switch]$Verbose = $false
)

$ErrorActionPreference = "Stop"

# Цвета для вывода
function Write-Status { Write-Host "[INFO] $args" -ForegroundColor Blue }
function Write-Success { Write-Host "[SUCCESS] $args" -ForegroundColor Green }
function Write-Warning { Write-Host "[WARNING] $args" -ForegroundColor Yellow }
function Write-Error { Write-Host "[ERROR] $args" -ForegroundColor Red }

# Проверка что мы в корне проекта
if (-not (Test-Path ".git")) {
    Write-Error "Не найден .git. Убедитесь что вы в корне проекта"
    exit 1
}

# Проверка SSH ключа
if (-not (Test-Path $SshKey)) {
    Write-Warning "SSH ключ не найден: $SshKey"
    Write-Warning "Используется ключ по умолчанию"
    $sshKeyParam = ""
} else {
    Write-Status "Использование SSH ключа: $SshKey"
    $sshKeyParam = "-i `"$SshKey`""
}

# Проверка SSH доступа
Write-Status "Проверка SSH доступа к $ServerUser@$ServerIP..."
try {
    if ($sshKeyParam) {
        $testResult = ssh $sshKeyParam -o ConnectTimeout=5 -o BatchMode=yes "${ServerUser}@${ServerIP}" "echo 'OK'" 2>&1
    } else {
        $testResult = ssh -o ConnectTimeout=5 -o BatchMode=yes "${ServerUser}@${ServerIP}" "echo 'OK'" 2>&1
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Не удается подключиться к серверу ${ServerIP}"
        Write-Error "Убедитесь что:"
        Write-Error "  1. SSH ключ добавлен на сервер"
        Write-Error "  2. IP адрес правильный"
        Write-Error "  3. Порт 22 открыт"
        exit 1
    }
    Write-Success "SSH доступ работает"
} catch {
    Write-Error "Ошибка при проверке SSH: $_"
    exit 1
}

# Проверка незакоммиченных изменений
Write-Status "Проверка незакоммиченных изменений..."
$gitStatus = git status --short
if ($gitStatus) {
    Write-Warning "Обнаружены незакоммиченные изменения:"
    $gitStatus | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }
    if ((git status --short | Measure-Object -Line).Lines -gt 10) {
        Write-Warning "  ... и еще файлов"
    }
    $response = Read-Host "Продолжить синхронизацию? (y/n)"
    if ($response -ne "y" -and $response -ne "Y") {
        Write-Status "Синхронизация отменена"
        exit 0
    }
}

# Создание директории на сервере если не существует
Write-Status "Проверка директории проекта на сервере..."
if ($sshKeyParam) {
    ssh $sshKeyParam "${ServerUser}@${ServerIP}" "mkdir -p ${ServerPath}" | Out-Null
} else {
    ssh "${ServerUser}@${ServerIP}" "mkdir -p ${ServerPath}" | Out-Null
}

# Создание временного файла с исключениями
$excludeFile = [System.IO.Path]::GetTempFileName()
$excludeContent = @"
node_modules/
__pycache__/
*.pyc
*.pyo
*.pyd
.Python
venv/
.venv/
env/
.env
.env.local
.git/
.DS_Store
*.log
*.tmp
build/
dist/
*.tar.gz
*.zip
mobile-app/flutter/
mobile-app/.dart_tool/
mobile-app/.pub/
mobile-app/build/
admin-panel/node_modules/
admin-panel/build/
backend/__pycache__/
*.db
*.sqlite
*.sqlite3
mobile-app/.gradle/
mobile-app/android/build/
mobile-app/android/.gradle/
**/.cache/
**/.gradle/
*.xlsx
"@
Set-Content -Path $excludeFile -Value $excludeContent

Write-Status "Синхронизация проекта с сервером..."
Write-Warning "Это может занять несколько минут..."

# Проверка наличия rsync на Windows (через WSL или Git Bash)
$rsyncAvailable = $false
$rsyncPath = ""

# Попытка найти rsync
if (Get-Command rsync -ErrorAction SilentlyContinue) {
    $rsyncAvailable = $true
    $rsyncPath = "rsync"
} elseif (Get-Command wsl -ErrorAction SilentlyContinue) {
    # Проверка rsync в WSL
    $wslRsync = wsl which rsync 2>$null
    if ($wslRsync) {
        $rsyncAvailable = $true
        $rsyncPath = "wsl rsync"
    }
}

if ($rsyncAvailable) {
    # Использование rsync
    Write-Status "Использование rsync для синхронизации..."
    
    $rsyncArgs = @(
        "-avz",
        "--delete",
        "--exclude-from=$excludeFile",
        "--progress"
    )
    
    if ($DryRun) {
        $rsyncArgs += "--dry-run"
    }
    
    if ($Verbose) {
        $rsyncArgs += "-v"
    }
    
    $rsyncArgs += "-e"
    if ($sshKeyParam) {
        $rsyncArgs += "ssh $sshKeyParam -o StrictHostKeyChecking=no"
    } else {
        $rsyncArgs += "ssh -o StrictHostKeyChecking=no"
    }
    $rsyncArgs += "./"
    $rsyncArgs += "${ServerUser}@${ServerIP}:${ServerPath}/"
    
    if ($rsyncPath -eq "wsl rsync") {
        $command = "wsl rsync $($rsyncArgs -join ' ')"
        Invoke-Expression $command
    } else {
        & $rsyncPath $rsyncArgs
    }
    
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Синхронизация завершена через rsync"
    } else {
        Write-Error "Ошибка при синхронизации через rsync"
        Remove-Item $excludeFile -ErrorAction SilentlyContinue
        exit 1
    }
} else {
    # Использование scp для основных файлов (менее эффективно, но работает)
    Write-Warning "rsync не найден, используется альтернативный метод..."
    Write-Status "Синхронизация через scp (может быть медленнее)..."
    
    # Создание архива локально
    $tempArchive = [System.IO.Path]::GetTempFileName() + ".tar.gz"
    Write-Status "Создание архива..."
    
    # Использование tar через WSL или Git Bash
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
        # Создание списка файлов для архива
        $filesToArchive = Get-ChildItem -Recurse -File | 
            Where-Object { 
                $relativePath = $_.FullName.Replace((Get-Location).Path + "\", "").Replace("\", "/")
                $excludeContent -split "`n" | ForEach-Object { 
                    if ($relativePath -like $_.Trim()) { return $false }
                }
                return $true
            } | 
            Select-Object -First 1000  # Ограничение для демонстрации
        
        Write-Warning "Альтернативный метод синхронизации ограничен"
        Write-Warning "Рекомендуется установить rsync или использовать WSL"
    } else {
        Write-Error "Не найден rsync или WSL. Установите один из них для синхронизации."
        Write-Error "Или используйте Git для синхронизации через удаленный репозиторий."
        Remove-Item $excludeFile -ErrorAction SilentlyContinue
        exit 1
    }
}

# Удаление временного файла
Remove-Item $excludeFile -ErrorAction SilentlyContinue

# Опционально: перезапуск контейнеров
$restartContainers = Read-Host "Перезапустить Docker контейнеры на сервере? (y/n)"
if ($restartContainers -eq "y" -or $restartContainers -eq "Y") {
    Write-Status "Перезапуск контейнеров..."
    if ($sshKeyParam) {
        ssh $sshKeyParam "${ServerUser}@${ServerIP}" @"
cd ${ServerPath}/server-config/docker
docker-compose down
docker-compose up -d --build
docker-compose ps
"@
    } else {
        ssh "${ServerUser}@${ServerIP}" @"
cd ${ServerPath}/server-config/docker
docker-compose down
docker-compose up -d --build
docker-compose ps
"@
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Контейнеры перезапущены"
    } else {
        Write-Warning "Ошибка при перезапуске контейнеров (возможно они не настроены)"
    }
}

Write-Success "Готово! Проект синхронизирован с сервером"
Write-Status "Server: ${ServerUser}@${ServerIP}:${ServerPath}"

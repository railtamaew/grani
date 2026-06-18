# Скрипт для сборки APK на сервере (Windows PowerShell)
# Использование: .\build-apk-on-server.ps1

$ErrorActionPreference = "Stop"

# Цвета
function Write-Status { Write-Host "[INFO] $args" -ForegroundColor Cyan }
function Write-Success { Write-Host "[SUCCESS] $args" -ForegroundColor Green }
function Write-Warning { Write-Host "[WARNING] $args" -ForegroundColor Yellow }
function Write-Error { Write-Host "[ERROR] $args" -ForegroundColor Red }

# Настройки
$SERVER_IP = "159.223.199.122"
$SERVER_USER = "root"
$SERVER_PATH = "/opt/grani"
$MOBILE_APP_PATH = "$SERVER_PATH/mobile-app"
$APK_REMOTE_PATH = "$MOBILE_APP_PATH/build/app/outputs/flutter-apk/app-debug.apk"
$APK_LOCAL_PATH = "$PSScriptRoot/../mobile-app/app-debug.apk"

Write-Status "Сборка APK на сервере..."

# 1. Проверка SSH доступа
Write-Status "[1/4] Проверка SSH доступа..."
try {
    $null = ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${SERVER_USER}@${SERVER_IP}" "echo OK" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Не удается подключиться к серверу"
    }
    Write-Success "SSH доступ работает"
} catch {
    Write-Error "Не удается подключиться к серверу ${SERVER_IP}"
    Write-Warning "Проверьте SSH ключи и доступность сервера"
    exit 1
}

# 2. Синхронизация проекта (опционально)
Write-Status "[2/4] Синхронизация проекта с сервером..."
$syncScript = "$PSScriptRoot/sync-to-server.sh"
if (Test-Path $syncScript) {
    Write-Warning "Для синхронизации используйте: bash $syncScript"
    Write-Warning "Пропускаем синхронизацию (требуется WSL или Git Bash)"
} else {
    Write-Warning "Скрипт синхронизации не найден, пропускаем"
}

# 3. Сборка APK на сервере
Write-Status "[3/4] Сборка APK на сервере..."
$buildCommands = @'
set -e
PROJECT_PATH="/opt/grani"
MOBILE_APP_PATH="${PROJECT_PATH}/mobile-app"

if [ ! -d "${MOBILE_APP_PATH}" ]; then
    echo "[ERROR] Проект не найден в ${MOBILE_APP_PATH}"
    exit 1
fi

cd "${MOBILE_APP_PATH}"

if ! command -v flutter > /dev/null 2>&1; then
    if [ -d "${MOBILE_APP_PATH}/flutter" ]; then
        export PATH="${MOBILE_APP_PATH}/flutter/bin:${PATH}"
    else
        echo "[ERROR] Flutter не установлен!"
        exit 1
    fi
fi

if [ -z "$ANDROID_HOME" ] && [ -z "$ANDROID_SDK_ROOT" ]; then
    if [ -d "$HOME/Android/Sdk" ]; then
        export ANDROID_HOME="$HOME/Android/Sdk"
        export ANDROID_SDK_ROOT="$HOME/Android/Sdk"
    elif [ -d "/opt/android-sdk" ]; then
        export ANDROID_HOME="/opt/android-sdk"
        export ANDROID_SDK_ROOT="/opt/android-sdk"
    else
        echo "[ERROR] Android SDK не найден!"
        exit 1
    fi
fi

echo "[INFO] Очистка проекта..."
flutter clean

echo "[INFO] Получение зависимостей..."
flutter pub get

echo "[INFO] Сборка APK..."
flutter build apk --debug

APK_FILE="${MOBILE_APP_PATH}/build/app/outputs/flutter-apk/app-debug.apk"
if [ -f "${APK_FILE}" ]; then
    APK_SIZE=$(du -h "${APK_FILE}" | cut -f1)
    echo "[SUCCESS] APK собран: ${APK_FILE} (${APK_SIZE})"
else
    echo "[ERROR] APK файл не найден!"
    exit 1
fi
'@

try {
    $buildOutput = ssh -o StrictHostKeyChecking=no "${SERVER_USER}@${SERVER_IP}" "bash -s" -InputObject $buildCommands 2>&1
    Write-Host $buildOutput
    
    if ($LASTEXITCODE -ne 0) {
        throw "Ошибка при сборке APK"
    }
    Write-Success "APK собран на сервере"
} catch {
    Write-Error "Ошибка при сборке APK на сервере: $_"
    exit 1
}

# 4. Скачивание APK
Write-Status "[4/4] Скачивание APK с сервера..."
$apkDir = Split-Path -Parent $APK_LOCAL_PATH
if (-not (Test-Path $apkDir)) {
    New-Item -ItemType Directory -Path $apkDir -Force | Out-Null
}

try {
    scp -o StrictHostKeyChecking=no "${SERVER_USER}@${SERVER_IP}:${APK_REMOTE_PATH}" $APK_LOCAL_PATH
    
    if (Test-Path $APK_LOCAL_PATH) {
        $apkSize = (Get-Item $APK_LOCAL_PATH).Length / 1MB
        Write-Success "APK скачан: $APK_LOCAL_PATH ($([math]::Round($apkSize, 2)) MB)"
        Write-Status ""
        Write-Status "APK готов к установке!"
        Write-Status "   Файл: $APK_LOCAL_PATH"
    } else {
        throw "APK файл не найден после скачивания"
    }
} catch {
    Write-Error "Ошибка при скачивании APK: $_"
    exit 1
}

Write-Success "Готово! APK собран и скачан"

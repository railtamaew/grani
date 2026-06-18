# Быстрая настройка ADB over Network

## Текущая ситуация

- Устройство OnePlus: IP `172.16.105.33`
- Сервер: `94.131.107.227`
- Устройство и сервер в разных сетях

## Решение: SSH туннель

### Шаг 1: Настройка на Windows компьютере (где подключено устройство)

Откройте PowerShell и выполните:

```powershell
# 1. Проверьте подключение устройства
adb devices

# 2. Включите TCP/IP режим ADB
adb tcpip 5555

# 3. Подключитесь к устройству локально
adb connect 172.16.105.33:5555

# 4. Проверьте подключение
adb devices
```

Должно показать:
```
List of devices attached
172.16.105.33:5555    device
```

### Шаг 2: Создайте SSH туннель

В новом окне PowerShell выполните:

```powershell
# Создайте SSH туннель (замените user на ваше имя пользователя)
ssh -R 5555:localhost:5555 user@94.131.107.227 -N
```

Эта команда:
- Создаст туннель от порта 5555 на сервере к порту 5555 на вашем компьютере
- `-N` означает, что не нужно выполнять команды, только туннель
- Оставьте это окно открытым

### Шаг 3: На сервере подключитесь к устройству

На сервере (в Cursor или другом терминале) выполните:

```bash
export PATH=$PATH:/opt/android-sdk/platform-tools
adb connect localhost:5555
adb devices
```

Должно показать устройство!

### Шаг 4: Используйте для разработки

```bash
/opt/grani/dev_run.sh
```

## Альтернатива: Автоматический скрипт для Windows

Создайте файл `setup_adb_tunnel.ps1` на Windows:

```powershell
# setup_adb_tunnel.ps1
Write-Host "Настройка ADB over network..." -ForegroundColor Cyan

# Включите TCP/IP режим
adb tcpip 5555
Start-Sleep -Seconds 2

# Подключитесь локально
$deviceIP = "172.16.105.33"
adb connect "${deviceIP}:5555"

Write-Host "Проверка подключения:" -ForegroundColor Green
adb devices

Write-Host ""
Write-Host "Создание SSH туннеля..." -ForegroundColor Cyan
Write-Host "Введите имя пользователя для SSH:" -ForegroundColor Yellow
$sshUser = Read-Host "SSH пользователь"

Write-Host "Подключение к серверу..." -ForegroundColor Cyan
ssh -R 5555:localhost:5555 ${sshUser}@94.131.107.227 -N
```

Запустите:
```powershell
.\setup_adb_tunnel.ps1
```

## Проверка

После настройки на сервере:

```bash
adb devices
```

Должно показать:
```
List of devices attached
localhost:5555    device
```

## Отключение

Чтобы отключить:
1. Закройте SSH туннель (Ctrl+C в окне PowerShell)
2. На сервере: `adb disconnect localhost:5555`

## Решение проблем

### "Connection refused" при подключении

- Убедитесь, что выполнили `adb tcpip 5555` на Windows
- Убедитесь, что SSH туннель запущен
- Проверьте, что устройство подключено: `adb devices` на Windows

### Устройство не видно на сервере

- Проверьте SSH туннель: он должен быть активен
- Попробуйте переподключиться: `adb disconnect localhost:5555 && adb connect localhost:5555`

### SSH требует пароль каждый раз

Настройте SSH ключи для автоматического подключения.






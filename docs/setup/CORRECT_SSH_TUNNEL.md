# Правильная настройка SSH туннеля для ADB

## ⚠️ ВАЖНО: Правильный сервер

- **Сервер разработки (где проект):** `159.223.199.122`
- **VPN сервер (WireGuard):** `94.131.107.227` (это НЕ сервер разработки!)

## Шаг 1: На Windows компьютере

### 1. Настройте ADB (если еще не сделали)

```powershell
cd C:\Users\railt\AppData\Local\Android\Sdk\platform-tools

# Проверьте подключение устройства
.\adb.exe devices

# Включите TCP/IP режим
.\adb.exe tcpip 5555

# Получите правильный IP адрес устройства
.\adb.exe -s f87272b8 shell "getprop dhcp.wlan0.ipaddress"

# Подключитесь к устройству локально (замените IP на правильный)
.\adb.exe connect ПРАВИЛЬНЫЙ_IP:5555

# Проверьте
.\adb.exe devices
```

### 2. Создайте SSH туннель

В **НОВОМ окне PowerShell** выполните:

```powershell
ssh -R 5555:localhost:5555 root@159.223.199.122 -N
```

**Важно:**
- Используйте `root@159.223.199.122` (правильный сервер!)
- Если SSH ключ настроен - пароль не потребуется
- **Оставьте это окно открытым** - туннель должен работать

## Шаг 2: На сервере разработки (159.223.199.122)

После создания туннеля, на сервере выполните:

```bash
export PATH=$PATH:/opt/android-sdk/platform-tools
adb connect localhost:5555
adb devices
```

Или просто запустите:

```bash
/opt/grani/dev_run.sh
```

## Проверка

После создания туннеля проверьте на сервере:

```bash
# Проверка порта
ss -tln | grep 5555

# Подключение к устройству
adb connect localhost:5555
adb devices
```

## Резюме команд

**На Windows:**
```powershell
# 1. Настройка ADB
cd C:\Users\railt\AppData\Local\Android\Sdk\platform-tools
.\adb.exe tcpip 5555
.\adb.exe connect ПРАВИЛЬНЫЙ_IP:5555

# 2. SSH туннель (в новом окне)
ssh -R 5555:localhost:5555 root@159.223.199.122 -N
```

**На сервере (159.223.199.122):**
```bash
adb connect localhost:5555
/opt/grani/dev_run.sh
```






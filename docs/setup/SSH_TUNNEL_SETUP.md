# Настройка SSH туннеля для ADB

## Пароль для SSH

Пароль нужен от **пользователя `rail` на сервере `159.223.199.122`**.

## Варианты подключения

### Вариант 1: Если SSH ключ уже настроен (рекомендуется)

Если вы уже подключаетесь к серверу через Cursor без пароля, значит SSH ключ настроен. Просто выполните:

```powershell
ssh -R 5555:localhost:5555 root@159.223.199.122 -N
```

Пароль **не потребуется**.

### Вариант 2: Если SSH ключ не настроен

#### 2.1. Использовать пароль

Просто введите пароль, когда SSH попросит:

```powershell
ssh -R 5555:localhost:5555 root@159.223.199.122 -N
```

Затем введите пароль пользователя `rail` на сервере.

#### 2.2. Настроить SSH ключ (чтобы не вводить пароль каждый раз)

**На Windows (PowerShell):**

1. **Проверьте, есть ли у вас SSH ключ:**
   ```powershell
   Get-Content $env:USERPROFILE\.ssh\id_rsa.pub
   ```
   
   Если файл не найден, создайте ключ:
   ```powershell
   ssh-keygen -t ed25519 -C "your_email@example.com"
   ```
   (Нажмите Enter для всех вопросов, или укажите пароль для ключа)

2. **Скопируйте публичный ключ:**
   ```powershell
   Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub | Set-Clipboard
   ```
   (Или `id_rsa.pub` если используете RSA)

3. **Добавьте ключ на сервер:**
   
   **Способ A: Если знаете пароль пользователя rail:**
   ```powershell
   Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub | ssh root@159.223.199.122 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh"
   ```
   (Введите пароль когда попросит)
   
   **Способ B: Если есть доступ через другого пользователя (например, root):**
   ```powershell
   # Сначала подключитесь как root
   ssh root@159.223.199.122
   
   # На сервере выполните:
   mkdir -p /home/rail/.ssh
   chmod 700 /home/rail/.ssh
   # Вставьте ваш публичный ключ в файл:
   nano /home/rail/.ssh/authorized_keys
   # (Вставьте скопированный ключ, сохраните: Ctrl+O, Enter, Ctrl+X)
   chmod 600 /home/rail/.ssh/authorized_keys
   chown -R rail:rail /home/rail/.ssh
   ```

4. **Проверьте подключение:**
   ```powershell
   ssh root@159.223.199.122 "echo 'Connection successful'"
   ```
   
   Если подключение работает без пароля - ключ настроен!

## После настройки SSH туннеля

1. **На Windows компьютере:**
   ```powershell
   # Настройте ADB (если еще не сделали)
   cd C:\Users\railt\AppData\Local\Android\Sdk\platform-tools
   .\adb.exe devices
   .\adb.exe tcpip 5555
   .\adb.exe connect 172.16.105.33:5555
   
   # Создайте SSH туннель (в новом окне PowerShell)
   ssh -R 5555:localhost:5555 root@159.223.199.122 -N
   ```

2. **На сервере:**
   ```bash
   export PATH=$PATH:/opt/android-sdk/platform-tools
   adb connect localhost:5555
   adb devices
   ```

## Если не знаете пароль

Если вы не знаете пароль пользователя `rail`, но у вас есть доступ через другого пользователя (например, `root`), можно:

1. **Создать новый пароль для пользователя rail:**
   ```bash
   # Подключитесь как root
   ssh root@159.223.199.122
   
   # На сервере установите новый пароль
   passwd rail
   ```

2. **Или настроить SSH ключ** (как в Варианте 2.2 выше)

## Проверка

После создания туннеля проверьте на сервере:

```bash
# Проверка порта
ss -tln | grep 5555

# Подключение к устройству
adb connect localhost:5555
adb devices
```


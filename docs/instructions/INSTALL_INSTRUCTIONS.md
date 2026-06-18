# Инструкция по установке APK на устройство

## Для пользователей Windows

Вы находитесь на Windows, а скрипты находятся на Linux сервере. 

### Быстрый запуск через SSH

**В PowerShell выполните:**

```powershell
# Замените на реальный адрес вашего сервера
ssh ваш-username@ваш-сервер-ip "/opt/grani/INSTALL_APK.sh"
```

**Или подключитесь интерактивно:**

```powershell
# 1. Подключитесь к серверу
ssh ваш-username@ваш-сервер-ip

# 2. После подключения выполните:
/opt/grani/INSTALL_APK.sh
```

### Как узнать адрес сервера?

Если вы работаете через Cursor и уже подключены к серверу, адрес сервера можно найти:
- В настройках SSH подключения Cursor
- В файлах конфигурации проекта
- Спросите у администратора сервера

### Способ 1: Подключение по SSH (рекомендуется)

1. **Установите SSH клиент** (если еще не установлен):
   - Windows 10/11: встроенный OpenSSH (доступен через PowerShell)
   - Или используйте PuTTY, MobaXterm, или другой SSH клиент

2. **Подключитесь к серверу:**
   ```powershell
   ssh username@server-ip
   # или
   ssh username@server-hostname
   ```

3. **Запустите скрипт установки:**
   ```bash
   /opt/grani/INSTALL_APK.sh
   ```

### Способ 2: Использование WSL (Windows Subsystem for Linux)

Если у вас установлен WSL:

```bash
# В WSL терминале
ssh username@server-ip
/opt/grani/install_and_run.sh
```

### Способ 3: Прямое выполнение через Python

Если у вас есть доступ к серверу через Python/API:

```python
import subprocess
result = subprocess.run(['ssh', 'user@server', '/opt/grani/install_apk.py'], 
                       capture_output=True, text=True)
print(result.stdout)
```

## Доступные скрипты

1. **`/opt/grani/install_and_run.sh`** - Основной скрипт установки
2. **`/opt/grani/install_apk.py`** - Python версия (сохраняет результаты в файл)
3. **`/opt/grani/install_with_output.sh`** - Версия с сохранением вывода

## Проверка результатов

После выполнения скрипта результаты будут в:
- `/opt/grani/install_result_YYYYMMDD_HHMMSS.txt` (Python версия)
- `/opt/grani/install_output_YYYYMMDD_HHMMSS.txt` (Bash версия)

## Что делает скрипт

1. ✅ Проверяет подключенные устройства (эмуляторы или физические устройства)
2. ✅ Находит или собирает APK файл
3. ✅ Устанавливает APK на устройство
4. ✅ Настраивает логирование (logcat)
5. ✅ Запускает приложение

## Требования

- Подключенное Android устройство по USB с включенной отладкой
- Или запущенный Android эмулятор
- ADB должен быть доступен в системе

## Быстрый запуск

Если у вас уже есть SSH доступ:

```bash
ssh user@server "/opt/grani/install_and_run.sh"
```

Или для просмотра вывода в реальном времени:

```bash
ssh user@server "/opt/grani/install_and_run.sh" | tee install_log.txt
```


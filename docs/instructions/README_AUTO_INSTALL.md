# Автоматическая установка и запуск APK

## Для AI ассистента (Cursor/Claude)

Для автоматического выполнения установки APK используйте следующие команды:

### 1. Запуск установки с сохранением вывода

```bash
/opt/grani/auto_install_apk.sh
```

Этот скрипт:
- Запускает установку APK
- Сохраняет весь вывод в `/opt/grani/.apk_install_output.log`
- Сохраняет статус в JSON формате в `/opt/grani/.apk_install_status.json`

### 2. Проверка статуса после выполнения

```bash
/opt/grani/check_apk_status.sh
```

Или прочитайте файлы напрямую:
- Статус: `/opt/grani/.apk_install_status.json`
- Полный вывод: `/opt/grani/.apk_install_output.log`

### 3. Для AI ассистента - последовательность действий

1. **Запустить установку:**
   ```bash
   /opt/grani/auto_install_apk.sh
   ```

2. **Подождать несколько секунд и проверить статус:**
   ```bash
   cat /opt/grani/.apk_install_status.json
   ```

3. **Прочитать вывод:**
   ```bash
   tail -50 /opt/grani/.apk_install_output.log
   ```

### Параметры

Все параметры основного скрипта поддерживаются:

```bash
# Пропустить сборку (использовать существующий APK)
/opt/grani/auto_install_apk.sh --skip-build

# Только запуск (если уже установлено)
/opt/grani/auto_install_apk.sh --skip-build --skip-install

# Без логирования
/opt/grani/auto_install_apk.sh --no-logs
```

### Формат статуса

Файл `.apk_install_status.json` содержит:

```json
{
    "timestamp": "20240101_120000",
    "status": "success|error|starting",
    "message": "Описание статуса",
    "step": "init|complete|error",
    "output_file": "/opt/grani/.apk_install_output.log"
}
```

### Пример использования в Python/скриптах

```python
import json
import subprocess
import time

# Запуск установки
subprocess.Popen(['/opt/grani/auto_install_apk.sh'])

# Ожидание и проверка статуса
time.sleep(5)
with open('/opt/grani/.apk_install_status.json') as f:
    status = json.load(f)
    print(f"Status: {status['status']}")
    print(f"Message: {status['message']}")
```







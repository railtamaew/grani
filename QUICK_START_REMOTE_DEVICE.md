# Быстрый старт: Удаленное устройство

## Для эмулятора

```bash
# 1. Диагностика и исправление
/opt/grani/scripts/fix_emulator.sh

# 2. Запуск эмулятора
/opt/grani/scripts/start_emulator_with_vnc.sh
```

## Для физического устройства

### На вашем компьютере:

1. **Скачайте скрипт:**
   ```bash
   scp root@granilink.com:/opt/grani/scripts/setup_adb_remote_client.sh ./
   chmod +x setup_adb_remote_client.sh
   ```

2. **Запустите:**
   ```bash
   ./setup_adb_remote_client.sh
   ```

### На сервере:

```bash
# Подключитесь к устройству
/opt/grani/scripts/connect_remote_device.sh

# Запустите приложение с логированием
/opt/grani/scripts/run_app_with_logging.sh
```

## Документация

- **Полное руководство:** `/opt/grani/docs/REMOTE_DEVICE_TESTING_GUIDE.md`
- **Исправление эмулятора:** `/opt/grani/docs/EMULATOR_FIX_GUIDE.md`
- **Отчет о реализации:** `/opt/grani/docs/reports/SOLUTIONS_IMPLEMENTATION_2026_01_20.md`

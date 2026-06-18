# 🚀 Быстрый старт комбинированного тестирования

## Один скрипт - вся система

```bash
# Запуск в ручном режиме (рекомендуется)
/opt/grani/scripts/start_combined_testing.sh manual
```

После запуска:
1. Откройте браузер по адресу: `http://<IP_СЕРВЕРА>:6080/vnc.html`
2. Вы увидите экран эмулятора
3. Когда появится диалог разрешения VPN - нажмите "Разрешить" мышью
4. Логи автоматически собираются в `/opt/grani/logs/android/`

## Просмотр логов

```bash
# В реальном времени
tail -f /opt/grani/logs/android/logcat_*.log
```

## Остановка

```bash
/opt/grani/scripts/stop_combined_testing.sh
```

## Автоматический режим

```bash
# Разрешения принимаются автоматически
/opt/grani/scripts/start_combined_testing.sh auto
```

## Запуск тестов

```bash
# Все тесты
/opt/grani/scripts/run_test_with_ui.sh all manual
```

---

📖 Полная документация: `/opt/grani/COMBINED_TESTING_GUIDE.md`

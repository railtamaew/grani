# Быстрое исправление эмулятора

## Проблема
Эмулятор падает: `Aborted (core dumped)`

## Решение (3 шага)

### Шаг 1: Создайте минимальный AVD
```bash
/opt/grani/scripts/create_minimal_avd.sh
```

### Шаг 2: Запустите систему
```bash
export AVD_NAME=grani_minimal
/opt/grani/scripts/start_combined_testing.sh manual
```

### Шаг 3: Откройте в браузере
```
http://<IP_СЕРВЕРА>:6080/vnc.html
```

## Что было исправлено

1. ✅ **Библиотеки** - добавлен `LD_LIBRARY_PATH` в скрипт
2. ✅ **Параметры запуска** - уменьшены до минимума:
   - RAM: 1536MB (было 2048MB)
   - CPU: 1 core (было 2)
   - Disk: 2048MB (было 3072MB)
   - Audio: отключен
   - Acceleration: отключен (работает без KVM)
3. ✅ **Создан минимальный AVD** - `grani_minimal` с оптимальными параметрами

## Если не работает

1. Проверьте логи: `tail -100 /opt/android-sdk/emulator.log`
2. Запустите диагностику: `/opt/grani/scripts/diagnose_emulator.sh`
3. Попробуйте другой AVD: `export AVD_NAME=grani_light_fixed`

## Документация

- Полное руководство: `/opt/grani/docs/EMULATOR_FIX_GUIDE.md`
- Troubleshooting: `/opt/grani/scripts/EMULATOR_TROUBLESHOOTING.md`

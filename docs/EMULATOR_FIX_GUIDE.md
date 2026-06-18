# Руководство по исправлению проблем с эмулятором

**Дата:** 2026-01-20  
**Версия:** 1.0

---

## Проблема

Эмулятор Android падает с ошибками:
- `ERROR elf_dynamic_array_reader.h:64] tag not found`
- `ERROR process_memory_range.cc:75] read out of range`
- `Aborted (core dumped)`

---

## Диагностика

### Шаг 1: Запуск диагностики

```bash
/opt/grani/scripts/fix_emulator.sh --diagnose-only
```

Скрипт проверит:
- ✅ Версию GLIBC
- ✅ Наличие библиотек
- ✅ X11 библиотеки
- ✅ LD_LIBRARY_PATH
- ✅ Системные ресурсы
- ✅ KVM поддержку
- ✅ Конфигурацию AVD

### Шаг 2: Анализ результатов

Скрипт покажет:
- Какие библиотеки отсутствуют
- Какие пути отсутствуют в LD_LIBRARY_PATH
- Проблемы с конфигурацией

---

## Исправление

### Вариант 1: Автоматическое исправление

```bash
/opt/grani/scripts/fix_emulator.sh
```

Скрипт автоматически:
- Установит недостающие библиотеки
- Обновит LD_LIBRARY_PATH
- Проверит конфигурацию AVD
- Выполнит тестовый запуск

### Вариант 2: Ручное исправление

#### 1. Установка библиотек

```bash
apt-get update
apt-get install -y \
    libx11-6 libx11-dev \
    libxext6 libxrender1 \
    libxtst6 libxi6 \
    libgl1-mesa-glx \
    libglib2.0-0
```

#### 2. Настройка LD_LIBRARY_PATH

Добавьте в `~/.bashrc` или в скрипт запуска эмулятора:

```bash
export LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu:/opt/android-sdk/emulator/lib64:/opt/android-sdk/emulator/lib64/qt/lib:${LD_LIBRARY_PATH}"
```

#### 3. Обновление скрипта запуска

Отредактируйте `/opt/grani/scripts/start_emulator_with_vnc.sh`:

```bash
# Добавьте в начало скрипта:
export LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu:/opt/android-sdk/emulator/lib64:/opt/android-sdk/emulator/lib64/qt/lib:${LD_LIBRARY_PATH}"
```

---

## Проверка GLIBC совместимости

### Проверка версии GLIBC

```bash
ldd --version
```

### Проверка требуемой версии для эмулятора

```bash
readelf -d /opt/android-sdk/emulator/qemu/linux-x86_64/qemu-system-x86_64 | grep NEEDED
```

### Если версии несовместимы

**Решение 1:** Обновить систему
```bash
apt-get update && apt-get upgrade
```

**Решение 2:** Использовать Docker с нужной версией GLIBC

---

## Альтернативные решения

### Решение 1: Запуск без ускорения

Отредактируйте скрипт запуска, добавьте флаги:
```bash
-no-accel
-no-snapshot
-gpu swiftshader_indirect
```

### Решение 2: Использование Docker

Создайте Dockerfile:
```dockerfile
FROM ubuntu:20.04
# Установка Android SDK и эмулятора
# ...
```

### Решение 3: Использование физического устройства

Если эмулятор не работает, используйте физическое устройство:
- Подключите через USB
- Или используйте удаленный доступ (см. REMOTE_DEVICE_TESTING_GUIDE.md)

---

## Тестирование после исправления

### Запуск эмулятора

```bash
/opt/grani/scripts/start_emulator_with_vnc.sh
```

### Проверка работы

```bash
# Проверка подключения
adb devices

# Проверка загрузки
adb wait-for-device
adb shell getprop sys.boot_completed
```

### Запуск приложения

```bash
/opt/grani/scripts/run_app_with_logging.sh
```

---

## Решение проблем

### Эмулятор все еще падает

1. **Проверьте логи:**
   ```bash
   dmesg | tail -50
   journalctl -xe | tail -50
   ```

2. **Проверьте память:**
   ```bash
   free -h
   ```

3. **Попробуйте другой AVD:**
   ```bash
   avdmanager list avd
   ```

### Ошибки с библиотеками

1. **Проверьте пути:**
   ```bash
   find /usr -name "libX11.so.6" 2>/dev/null
   ```

2. **Создайте символические ссылки:**
   ```bash
   ln -s /usr/lib/x86_64-linux-gnu/libX11.so.6 /opt/android-sdk/emulator/lib64/
   ```

### Проблемы с KVM

Если `/dev/kvm` недоступен:
- Эмулятор будет работать медленнее
- Используйте `-no-accel` флаг
- Или настройте KVM (требует root)

---

## Итоги

✅ **Создан скрипт диагностики и исправления:**
- `/opt/grani/scripts/fix_emulator.sh`

✅ **Возможные решения:**
- Автоматическое исправление LD_LIBRARY_PATH
- Установка недостающих библиотек
- Проверка GLIBC совместимости
- Альтернативные варианты запуска

---

**Дата:** 2026-01-20  
**Версия:** 1.0

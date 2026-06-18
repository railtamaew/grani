# Решение проблем с эмулятором - Пошаговая инструкция

## Проблема
Эмулятор падает при запуске: `Aborted (core dumped)`

## Быстрое решение

### Шаг 1: Создайте минимальный AVD
```bash
/opt/grani/scripts/create_minimal_avd.sh
```

### Шаг 2: Запустите с новым AVD
```bash
export AVD_NAME=grani_minimal
/opt/grani/scripts/start_combined_testing.sh manual
```

### Шаг 3: Откройте в браузере
```
http://<IP_СЕРВЕРА>:6080/vnc.html
```

## Детальная диагностика

### 1. Проверка библиотек
```bash
export LD_LIBRARY_PATH="/opt/android-sdk/emulator/lib64:/opt/android-sdk/emulator/lib64/qt/lib"
ldd /opt/android-sdk/emulator/qemu/linux-x86_64/qemu-system-x86_64 | grep "not found"
```
**Если есть "not found"** - проблема с библиотеками (уже исправлено в скрипте)

### 2. Проверка ресурсов
```bash
df -h /        # Нужно минимум 5GB свободно
free -h        # Нужно минимум 2GB свободной RAM
```
**Если мало места** - запустите: `/opt/grani/scripts/cleanup_10gb.sh`

### 3. Проверка AVD
```bash
avdmanager list avd
du -sh /root/.android/avd/*/userdata*.img
```
**Если userdata.img > 6GB** - создайте новый AVD

### 4. Проверка виртуализации
```bash
lsmod | grep kvm
```
**Если KVM нет** - не критично, эмулятор работает без него (медленнее)

## Решения по проблемам

### Проблема: Отсутствующие библиотеки
**Решение:** ✅ Уже исправлено - добавлен `LD_LIBRARY_PATH` в скрипт

### Проблема: Нехватка ресурсов
**Решение:**
1. Освободите место: `/opt/grani/scripts/cleanup_10gb.sh`
2. Используйте минимальный AVD: `grani_minimal` (1536MB RAM, 2GB disk)

### Проблема: Большой AVD
**Решение:**
1. Удалите старый: `avdmanager delete avd -n grani_light`
2. Создайте новый: `/opt/grani/scripts/create_minimal_avd.sh`

### Проблема: Виртуализация
**Решение:** Не критично - эмулятор работает без KVM (используется `-no-accel`)

## Обновленный скрипт запуска

Скрипт `start_emulator_with_vnc.sh` обновлен с минимальными параметрами:
- RAM: 1536MB (было 2048MB)
- CPU: 1 core (было 2)
- Data partition: 2048MB (было 3072MB)
- Audio: отключен (меньше нагрузка)
- Acceleration: отключен (работает без KVM)

## Тестирование

После исправления попробуйте:
```bash
# Вариант 1: С существующим AVD (grani_light)
/opt/grani/scripts/start_combined_testing.sh manual

# Вариант 2: С новым минимальным AVD
export AVD_NAME=grani_minimal
/opt/grani/scripts/start_combined_testing.sh manual
```

## Если все еще не работает

1. **Проверьте логи:**
```bash
tail -100 /opt/android-sdk/emulator.log
```

2. **Попробуйте другую версию Android:**
```bash
sdkmanager "system-images;android-29;default;x86_64"
avdmanager create avd -n grani_android29 -k "system-images;android-29;default;x86_64" -d pixel
export AVD_NAME=grani_android29
```

3. **Используйте Docker контейнер** (альтернатива):
```bash
docker run -d -p 5901:5901 -p 6080:6080 --name android-emulator budtmo/docker-android-x86-11.0
```

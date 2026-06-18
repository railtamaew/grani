# Руководство по тестированию на удаленном физическом устройстве

**Дата:** 2026-01-20  
**Версия:** 1.0

---

## Обзор

Это руководство описывает, как настроить тестирование VPN приложения на физическом Android устройстве, которое не подключено напрямую к серверу. Система использует ADB over WiFi и SSH туннели для удаленного доступа и сбора логов.

---

## Архитектура

```
[Ваш телефон] 
    ↓ (WiFi ADB)
[Ваш компьютер] 
    ↓ (SSH туннель)
[Наш сервер] 
    ↓ (ADB + logcat)
[Логи и тесты]
```

---

## Вариант 1: ADB over WiFi (устройство и сервер в одной сети)

### Шаг 1: Настройка на вашем компьютере

**Требования:**
- Android устройство подключено к Wi-Fi
- ADB установлен на вашем компьютере
- Устройство и сервер в одной сети

**Выполните:**

```bash
# 1. Скачайте скрипт с сервера
scp root@granilink.com:/opt/grani/scripts/setup_adb_remote_client.sh ./

# 2. Запустите скрипт
chmod +x setup_adb_remote_client.sh
./setup_adb_remote_client.sh
```

Скрипт автоматически:
- Найдет подключенное устройство
- Получит IP адрес
- Включит TCP/IP режим ADB
- Подключится по сети
- Создаст SSH туннель к серверу

### Шаг 2: Настройка на сервере

```bash
# На сервере выполните:
/opt/grani/scripts/setup_adb_remote_server.sh

# Или вручную:
adb connect localhost:5555
adb devices
```

---

## Вариант 2: ADB через SSH туннель (устройство и сервер в разных сетях)

### Шаг 1: Настройка на вашем компьютере

**Требования:**
- Android устройство подключено к вашему компьютеру (USB или WiFi)
- SSH доступ к серверу

**Выполните:**

```bash
# 1. Подключите устройство по USB или WiFi ADB
adb devices

# 2. Включите TCP/IP режим
adb tcpip 5555

# 3. Получите IP адрес устройства
DEVICE_IP=$(adb shell "getprop dhcp.wlan0.ipaddress" | tr -d '\r')
echo "IP устройства: $DEVICE_IP"

# 4. Подключитесь локально
adb connect ${DEVICE_IP}:5555

# 5. Создайте SSH туннель к серверу
ssh -R 5555:localhost:5555 root@granilink.com -N &
TUNNEL_PID=$!

echo "SSH туннель создан (PID: $TUNNEL_PID)"
echo "Оставьте это окно открытым"
```

### Шаг 2: Настройка на сервере

```bash
# На сервере выполните:
/opt/grani/scripts/connect_remote_device.sh

# Или вручную:
adb connect localhost:5555
adb devices
```

---

## Вариант 3: Беспроводная отладка (Android 11+)

### Шаг 1: Настройка на устройстве

1. **Включите режим разработчика:**
   - Настройки → О телефоне → Номер сборки (нажмите 7 раз)

2. **Включите беспроводную отладку:**
   - Настройки → Для разработчиков → Беспроводная отладка
   - Включите "Беспроводная отладка"
   - Нажмите "Параметры беспроводной отладки"
   - Запишите IP адрес и порт (например, `192.168.1.100:12345`)

### Шаг 2: Настройка на вашем компьютере

```bash
# Подключитесь к устройству
adb connect 192.168.1.100:12345

# Создайте SSH туннель
ssh -R 5555:localhost:12345 root@granilink.com -N &
```

### Шаг 3: Настройка на сервере

```bash
adb connect localhost:5555
adb devices
```

---

## Использование

### Проверка подключения

```bash
# На сервере:
adb devices

# Должно показать:
# List of devices attached
# localhost:5555    device
```

### Запуск приложения с логированием

```bash
# На сервере:
/opt/grani/scripts/run_app_with_logging.sh
```

Скрипт автоматически:
- Найдет удаленное устройство
- Установит APK
- Запустит приложение
- Начнет сбор логов

### Мониторинг логов в реальном времени

```bash
# На сервере:
/opt/grani/scripts/start_logcat_monitor.sh

# Просмотр логов:
tail -f /opt/grani/logs/android/logcat_*.log
```

### Автоматический сбор логов

```bash
# Сбор логов в течение 5 минут:
/opt/grani/scripts/collect_remote_logs.sh 300

# Логи сохраняются в:
# /opt/grani/logs/android/remote/remote_logcat_*.log
```

### Запуск тестов

```bash
# Android тесты:
cd /opt/grani/mobile-app/android
./gradlew connectedDebugAndroidTest

# Flutter тесты:
cd /opt/grani/mobile-app
flutter test
```

---

## Решение проблем

### Устройство не видно в `adb devices`

**Проблема:** Устройство не подключено через туннель

**Решение:**
1. Проверьте SSH туннель на клиентской машине:
   ```bash
   ps aux | grep "ssh.*5555"
   ```

2. Переподключитесь:
   ```bash
   adb disconnect localhost:5555
   adb connect localhost:5555
   ```

3. Перезапустите ADB:
   ```bash
   adb kill-server
   adb start-server
   adb devices
   ```

### SSH туннель не работает

**Проблема:** Туннель не создается или разрывается

**Решение:**
1. Проверьте SSH подключение:
   ```bash
   ssh root@granilink.com "echo 'Connected'"
   ```

2. Создайте туннель с автопереподключением:
   ```bash
   while true; do
       ssh -R 5555:localhost:5555 root@granilink.com -N -o ServerAliveInterval=60
       sleep 5
   done
   ```

3. Используйте autossh для автоматического переподключения:
   ```bash
   autossh -M 20000 -R 5555:localhost:5555 root@granilink.com -N
   ```

### Устройство отключается

**Проблема:** Устройство периодически отключается

**Решение:**
1. Отключите энергосбережение Wi-Fi на устройстве
2. Используйте "Беспроводная отладка" (Android 11+) вместо TCP/IP
3. Настройте автопереподключение в скрипте

### Логи не собираются

**Проблема:** logcat не работает с удаленным устройством

**Решение:**
1. Проверьте подключение:
   ```bash
   adb -s localhost:5555 shell "echo 'test'"
   ```

2. Используйте явное указание устройства:
   ```bash
   adb -s localhost:5555 logcat
   ```

3. Проверьте фильтры в скрипте `start_logcat_monitor.sh`

---

## Полезные команды

### На сервере

```bash
# Список устройств
adb devices

# Подключение к shell
adb -s localhost:5555 shell

# Просмотр логов
adb -s localhost:5555 logcat

# Установка APK
adb -s localhost:5555 install -r app-debug.apk

# Запуск приложения
adb -s localhost:5555 shell am start -n com.granivpn.mobile/.MainActivity

# Остановка приложения
adb -s localhost:5555 shell am force-stop com.granivpn.mobile

# Получение информации об устройстве
adb -s localhost:5555 shell getprop ro.product.model
adb -s localhost:5555 shell getprop ro.build.version.release
```

### На клиентской машине

```bash
# Проверка подключения
adb devices

# Перезапуск ADB
adb kill-server && adb start-server

# Проверка SSH туннеля
ps aux | grep "ssh.*5555"

# Остановка туннеля
pkill -f "ssh.*5555"
```

---

## Автоматизация

### Скрипт для постоянного мониторинга

Создайте скрипт на клиентской машине для автоматического поддержания туннеля:

```bash
#!/bin/bash
# keep_tunnel_alive.sh

while true; do
    if ! ps aux | grep -q "[s]sh.*5555"; then
        echo "Туннель разорван, переподключение..."
        ssh -R 5555:localhost:5555 root@granilink.com -N &
    fi
    sleep 60
done
```

### Автозапуск при загрузке

Добавьте в `~/.bashrc` или `~/.profile`:

```bash
# Автоподключение ADB туннеля
if command -v adb &> /dev/null; then
    ssh -f -N -R 5555:localhost:5555 root@granilink.com
fi
```

---

## Безопасность

### Рекомендации

1. **Используйте SSH ключи** вместо паролей
2. **Ограничьте доступ** к порту 5555 на сервере
3. **Используйте VPN** для дополнительной безопасности
4. **Не оставляйте туннели открытыми** без необходимости

### Настройка firewall

```bash
# На сервере (если нужно открыть порт):
ufw allow from YOUR_IP to any port 5555
```

---

## Итоги

✅ **Создана система удаленного доступа:**
- Скрипты для клиентской машины
- Скрипты для сервера
- Автоматический сбор логов
- Документация

✅ **Преимущества:**
- Телефон может быть в любой сети
- Логи собираются на сервере
- Полный доступ через ADB
- Автоматизация тестирования

---

**Дата:** 2026-01-20  
**Версия:** 1.0

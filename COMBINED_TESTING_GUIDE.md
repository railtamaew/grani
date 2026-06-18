# Руководство по комбинированному тестированию VPN

## Обзор

Комбинированная система тестирования позволяет:
- **Вам**: Видеть интерфейс эмулятора в браузере и давать разрешения VPN вручную
- **AI (Cursor)**: Видеть логи в реальном времени для анализа проблем

## Быстрый старт

### Ручной режим (рекомендуется для отладки)

```bash
# Запуск всей системы
/opt/grani/scripts/start_combined_testing.sh manual

# Откройте браузер по адресу, который будет показан
# Обычно: http://<IP_СЕРВЕРА>:6080/vnc.html

# Когда появится диалог разрешения VPN, нажмите "Разрешить" мышью
```

### Автоматический режим (для автоматических тестов)

```bash
# Запуск с автоматическим принятием разрешений
/opt/grani/scripts/start_combined_testing.sh auto
```

## Компоненты системы

### 1. Эмулятор с VNC
- **Скрипт**: `start_emulator_with_vnc.sh`
- **Порт VNC**: 5901
- **Память**: 2048 MB
- **Ядра**: 2

### 2. noVNC веб-интерфейс
- **Скрипт**: `start_novnc.sh`
- **Веб-порт**: 6080
- **Доступ**: `http://<IP>:6080/vnc.html`

### 3. Мониторинг логов
- **Скрипт**: `start_logcat_monitor.sh`
- **Логи**: `/opt/grani/logs/android/logcat_*.log`
- **Фильтрация**: по пакету и ключевым словам

### 4. Автоматическое принятие разрешений
- **Скрипт**: `auto_grant_vpn_permission.sh`
- **Методы**: координаты, клавиши, UI Automator

## Использование

### Запуск системы

```bash
# Ручной режим (вы даете разрешения через браузер)
/opt/grani/scripts/start_combined_testing.sh manual

# Автоматический режим (разрешения принимаются автоматически)
/opt/grani/scripts/start_combined_testing.sh auto
```

### Просмотр логов

```bash
# В реальном времени
tail -f /opt/grani/logs/android/logcat_*.log

# Последние 100 строк
tail -100 /opt/grani/logs/android/logcat_*.log

# Поиск по ключевым словам
grep -i "vpn\|error\|exception" /opt/grani/logs/android/logcat_*.log
```

### Запуск тестов

```bash
# Все тесты
/opt/grani/scripts/run_test_with_ui.sh all manual

# Интеграционные тесты
/opt/grani/scripts/run_test_with_ui.sh integration manual

# Тесты VPN сервиса
/opt/grani/scripts/run_test_with_ui.sh vpn_service manual

# Конкретный тест
/opt/grani/scripts/run_test_with_ui.sh test/services/vpn_service_test.dart manual
```

### Остановка системы

```bash
/opt/grani/scripts/stop_combined_testing.sh
```

## Индивидуальные скрипты

### Запуск эмулятора с VNC

```bash
/opt/grani/scripts/start_emulator_with_vnc.sh
```

### Запуск noVNC веб-интерфейса

```bash
/opt/grani/scripts/start_novnc.sh
```

### Запуск мониторинга логов

```bash
/opt/grani/scripts/start_logcat_monitor.sh
```

### Остановка компонентов

```bash
# Остановка noVNC
/opt/grani/scripts/stop_novnc.sh

# Остановка logcat
/opt/grani/scripts/stop_logcat_monitor.sh

# Остановка эмулятора
pkill -f "emulator.*grani_emulator"
```

## Рабочий процесс

### 1. Отладка проблем VPN

```bash
# 1. Запустите систему в ручном режиме
/opt/grani/scripts/start_combined_testing.sh manual

# 2. Откройте браузер и перейдите по адресу
# http://<IP>:6080/vnc.html

# 3. В браузере:
#    - Установите APK (если нужно)
#    - Запустите приложение
#    - Дайте разрешение VPN когда появится диалог

# 4. В другом терминале смотрите логи
tail -f /opt/grani/logs/android/logcat_*.log

# 5. AI (Cursor) анализирует логи и предлагает решения
```

### 2. Автоматическое тестирование

```bash
# 1. Запустите систему в автоматическом режиме
/opt/grani/scripts/start_combined_testing.sh auto

# 2. Запустите тесты
/opt/grani/scripts/run_test_with_ui.sh integration auto

# 3. Проверьте результаты и логи
```

## Решение проблем

### Эмулятор не запускается

```bash
# Проверьте наличие AVD
avdmanager list avd

# Если нет, создайте:
/opt/grani/setup_emulator.sh
```

### VNC не доступен

```bash
# Проверьте порт
nc -z localhost 5901

# Проверьте логи эмулятора
tail -f /opt/android-sdk/emulator.log
```

### noVNC не работает

```bash
# Проверьте websockify
ps aux | grep websockify

# Проверьте логи
cat /tmp/websockify.log

# Перезапустите
/opt/grani/scripts/stop_novnc.sh
/opt/grani/scripts/start_novnc.sh
```

### Логи не собираются

```bash
# Проверьте устройство
adb devices

# Проверьте процесс logcat
ps aux | grep logcat

# Перезапустите
/opt/grani/scripts/stop_logcat_monitor.sh
/opt/grani/scripts/start_logcat_monitor.sh
```

### Разрешение VPN не принимается автоматически

```bash
# Используйте ручной режим
/opt/grani/scripts/start_combined_testing.sh manual

# Или попробуйте вручную через браузер
```

## Мониторинг ресурсов

### Использование памяти

```bash
free -h
```

### Использование диска

```bash
df -h
```

### Процессы эмулятора

```bash
ps aux | grep emulator
```

## Преимущества комбинированного подхода

1. **Скорость**: Не нужно копировать логи вручную
2. **Интерактивность**: Можно давать разрешения через браузер
3. **Автоматизация**: Можно автоматизировать принятие разрешений
4. **Прозрачность**: Видно что происходит в реальном времени
5. **Гибкость**: Можно переключаться между ручным и автоматическим режимами

## Следующие шаги

1. Запустите систему: `/opt/grani/scripts/start_combined_testing.sh manual`
2. Откройте браузер и подключитесь к noVNC
3. Установите APK и запустите приложение
4. Дайте разрешение VPN через браузер
5. Смотрите логи в реальном времени
6. AI анализирует проблемы и предлагает решения

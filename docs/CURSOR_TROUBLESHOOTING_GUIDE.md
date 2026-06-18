# Руководство по устранению проблем с генерацией планов в Cursor

## Быстрая диагностика

### Шаг 1: Запустите скрипт проверки

#### На Linux/Mac:
```bash
cd /opt/grani/scripts
./check_cursor_api.sh
```

#### На Windows (PowerShell):
```powershell
cd C:\path\to\grani\scripts
.\check_cursor_api.ps1
```

### Шаг 2: Проверьте логи Cursor

#### Windows:
```
%APPDATA%\Cursor\logs\
```

#### Mac:
```
~/Library/Application Support/Cursor/logs/
```

#### Linux:
```
~/.config/Cursor/logs/
```

Ищите ошибки типа:
- `Connection timeout`
- `DNS resolution failed`
- `API request failed`
- `Network error`

### Шаг 3: Проверьте настройки Cursor

1. Откройте Cursor
2. Нажмите `Ctrl+,` (или `Cmd+,` на Mac) для настроек
3. Найдите раздел "Network" или "Proxy"
4. Проверьте, не установлен ли прокси, который может блокировать доступ

### Шаг 4: Проверьте версию Cursor

1. В Cursor: `Help → About`
2. Убедитесь, что используется последняя версия
3. Если нет - обновите Cursor

## Детальная диагностика

### Проблема: Планы не генерируются вообще

**Возможные причины:**
1. API Cursor недоступен
2. Проблемы с сетью/прокси
3. Устаревшая версия Cursor
4. Проблемы с кэшем Cursor

**Решение:**
1. ✅ Запустите скрипт проверки (см. выше)
2. ✅ Проверьте логи Cursor
3. ✅ Обновите Cursor до последней версии
4. ✅ Очистите кэш Cursor:
   - Закройте Cursor полностью
   - Удалите кэш (см. раздел "Очистка кэша")
   - Перезапустите Cursor

### Проблема: Планы генерируются очень медленно (>5 минут)

**Возможные причины:**
1. Медленное интернет-соединение
2. Проблемы с API Cursor (высокая нагрузка)
3. Прокси добавляет задержку

**Решение:**
1. ✅ Проверьте скорость интернета
2. ✅ Попробуйте с другого интернет-соединения
3. ✅ Проверьте настройки прокси
4. ✅ Подождите - возможно временная проблема на стороне Cursor

### Проблема: Планы не генерируются на нескольких устройствах

**Возможные причины:**
1. Все устройства в одной сети с ограничениями
2. Проблема с API Cursor (временная)
3. Корпоративный firewall блокирует доступ

**Решение:**
1. ✅ Проверьте, работает ли Cursor на устройствах вне этой сети
2. ✅ Проверьте настройки корпоративного firewall
3. ✅ Обратитесь к IT-отделу для проверки логов firewall
4. ✅ Попробуйте с мобильного интернета (не через корпоративную сеть)

## Очистка кэша Cursor

### Windows:
```powershell
# Закройте Cursor полностью, затем:
Remove-Item -Recurse -Force "$env:APPDATA\Cursor\Cache"
Remove-Item -Recurse -Force "$env:APPDATA\Cursor\Code Cache"
Remove-Item -Recurse -Force "$env:APPDATA\Cursor\GPUCache"
```

### Mac:
```bash
# Закройте Cursor полностью, затем:
rm -rf ~/Library/Application\ Support/Cursor/Cache
rm -rf ~/Library/Application\ Support/Cursor/Code\ Cache
rm -rf ~/Library/Application\ Support/Cursor/GPUCache
```

### Linux:
```bash
# Закройте Cursor полностью, затем:
rm -rf ~/.config/Cursor/Cache
rm -rf ~/.config/Cursor/Code\ Cache
rm -rf ~/.config/Cursor/GPUCache
```

## Проверка сетевых настроек

### Проверка DNS

#### Windows:
```powershell
nslookup cursor.sh
nslookup api.cursor.sh
```

#### Linux/Mac:
```bash
nslookup cursor.sh
nslookup api.cursor.sh
# или
dig cursor.sh
dig api.cursor.sh
```

### Проверка доступности сайтов

#### Windows:
```powershell
Test-NetConnection cursor.sh -Port 443
Test-NetConnection api.cursor.sh -Port 443
```

#### Linux/Mac:
```bash
curl -I https://cursor.sh
curl -I https://api.cursor.sh
```

### Проверка прокси

#### Windows:
```powershell
$env:HTTP_PROXY
$env:HTTPS_PROXY
```

#### Linux/Mac:
```bash
echo $HTTP_PROXY
echo $HTTPS_PROXY
```

## Альтернативные решения

### Если API Cursor недоступен:

1. **Создавайте планы вручную**
   - Используйте инструмент `todo_write` вручную
   - Создавайте задачи вручную в Cursor

2. **Используйте другие инструменты**
   - GitHub Issues
   - Trello
   - Notion
   - Другие инструменты планирования

3. **Ожидайте восстановления сервиса**
   - Проверьте статус Cursor (Twitter, Discord, GitHub)
   - Проблема может быть временной

## Мониторинг проблемы

### Проверка статуса Cursor:
- Twitter: [@cursor_ai](https://twitter.com/cursor_ai)
- Discord: [Cursor Discord](https://discord.gg/cursor)
- GitHub Issues: [Cursor GitHub](https://github.com/getcursor/cursor/issues)

### Сбор информации для отчета:

Если проблема продолжается, соберите:
1. ✅ Результаты скрипта проверки
2. ✅ Логи Cursor (последние 100 строк)
3. ✅ Версию Cursor
4. ✅ Информацию о сети (провайдер, корпоративная/домашняя)
5. ✅ Скриншоты ошибок (если есть)

## Контакты для поддержки

- **Cursor Support**: support@cursor.sh
- **Cursor Discord**: Для обсуждения проблем с сообществом
- **GitHub Issues**: Для багов и проблем

---

**Важно**: Проблема НЕ связана с вашим сервером. Ограничения на сервере (Nginx timeout, rate limiting) влияют только на ваш API, а не на работу Cursor.

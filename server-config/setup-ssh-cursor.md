# Быстрая настройка Cursor для работы через SSH

## Шаг 1: Установка расширения Remote-SSH

1. Откройте Cursor
2. Нажмите `Ctrl+Shift+X` (Windows/Linux) или `Cmd+Shift+X` (Mac)
3. Найдите **"Remote - SSH"** (от Microsoft)
4. Нажмите **Install**

## Шаг 2: Настройка SSH config

### Windows

Откройте файл: `C:\Users\ВАШЕ_ИМЯ\.ssh\config`

Если файла нет, создайте его.

### Linux/macOS

Откройте файл: `~/.ssh/config`

```bash
nano ~/.ssh/config
```

### Добавьте конфигурацию:

```ssh-config
Host grani
    HostName YOUR_DROPLET_IP
    User root
    IdentityFile ~/.ssh/id_ed25519
    Port 22
    ServerAliveInterval 60
    ServerAliveCountMax 3
```

**Замените:**
- `YOUR_DROPLET_IP` - на IP адрес вашего дроплета
- `root` - на ваше имя пользователя (если используете другого)
- `~/.ssh/id_ed25519` - на путь к вашему SSH ключу

## Шаг 3: Подключение

1. В Cursor нажмите `F1` (или `Ctrl+Shift+P` / `Cmd+Shift+P`)
2. Введите: **"Remote-SSH: Connect to Host"**
3. Выберите: **grani**
4. Дождитесь подключения (первый раз может занять время)

## Шаг 4: Открытие проекта

1. После подключения нажмите **"Open Folder"**
2. Введите: `/opt/grani`
3. Нажмите **OK**

## Готово! 🎉

Теперь вы работаете с проектом напрямую на сервере.

### Полезные команды в терминале Cursor:

```bash
# Статус Docker
cd /opt/grani/server-config/docker
docker compose ps

# Логи
docker compose logs -f

# Перезапуск
docker compose restart
```

### Отключение:

- Просто закройте окно Cursor или выберите **"Remote-SSH: Close Remote Connection"**


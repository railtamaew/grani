# Инструкция по добавлению сервера в БД

**Дата:** 2025-01-XX  
**Сервер:** 45.12.132.94

## Способ 1: Через скрипт (рекомендуется)

### Подготовка

1. Убедитесь, что backend запущен:
   ```bash
   cd /opt/grani/backend
   # Запустите сервер, если еще не запущен
   ```

2. Получите токен администратора:
   ```bash
   curl -X POST http://localhost:8000/api/auth/login \
     -H "Content-Type: application/json" \
     -d '{"email": "admin@example.com", "password": "your_password"}'
   ```

### Использование скрипта

```bash
cd /opt/grani
python scripts/add_server_to_db.py \
  --email admin@example.com \
  --password your_password \
  --test-connection \
  --install-wg
```

**Параметры:**
- `--email` - Email администратора
- `--password` - Пароль администратора
- `--token` - Токен авторизации (если уже есть)
- `--api-url` - URL API (по умолчанию: http://localhost:8000)
- `--test-connection` - Протестировать SSH подключение после создания
- `--install-wg` - Установить WireGuard после создания

### Пример использования с токеном

```bash
python scripts/add_server_to_db.py \
  --token "your_access_token" \
  --test-connection \
  --install-wg
```

## Способ 2: Через API напрямую

### 1. Получение токена

```bash
TOKEN=$(curl -X POST http://localhost:8000/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email": "admin@example.com", "password": "your_password"}' \
  | jq -r '.access_token')
```

### 2. Создание сервера

```bash
curl -X POST http://localhost:8000/api/servers \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Test Server 1",
    "ip_address": "45.12.132.94",
    "country": "RU",
    "city": "Moscow",
    "ssh_host": "45.12.132.94",
    "ssh_port": 22,
    "ssh_user": "root",
    "ssh_password": "c75aZ83oIpx0",
    "wireguard_port": 51820,
    "supported_protocols": ["wireguard"],
    "is_local": false
  }'
```

### 3. Тестирование подключения

```bash
SERVER_ID=1  # Замените на ID созданного сервера

curl -X POST http://localhost:8000/api/servers/$SERVER_ID/test-connection \
  -H "Authorization: Bearer $TOKEN"
```

### 4. Установка WireGuard

```bash
curl -X POST http://localhost:8000/api/servers/$SERVER_ID/install-wireguard \
  -H "Authorization: Bearer $TOKEN"
```

## Способ 3: Через Admin панель

1. Откройте admin панель в браузере
2. Перейдите в раздел "Servers"
3. Нажмите "Add Server"
4. Заполните форму:
   - Name: Test Server 1
   - IP Address: 45.12.132.94
   - Country: RU
   - City: Moscow
   - SSH Host: 45.12.132.94
   - SSH Port: 22
   - SSH User: root
   - SSH Password: c75aZ83oIpx0
   - WireGuard Port: 51820
   - Supported Protocols: wireguard
5. Нажмите "Save"

## Данные сервера

- **IP адрес:** 45.12.132.94
- **Пользователь:** root
- **Пароль:** c75aZ83oIpx0 (временный, для тестирования)
- **SSH порт:** 22
- **WireGuard порт:** 51820
- **Протоколы:** wireguard

## Важные замечания

### Безопасность

1. **SSH ключи вместо пароля:**
   - В продакшене НЕ используйте пароли
   - Настройте SSH ключи:
     ```bash
     ssh-keygen -t rsa -b 4096 -f ~/.ssh/grani_vpn_server
     ssh-copy-id -i ~/.ssh/grani_vpn_server.pub root@45.12.132.94
     ```
   - Используйте `ssh_key_path` или `ssh_key_content` вместо `ssh_password`

2. **Шифрование ключей:**
   - SSH ключи должны храниться в зашифрованном виде
   - Не храните ключи в открытом виде в БД

3. **Удаление пароля:**
   - После настройки SSH ключей удалите пароль из конфигурации
   - Обновите сервер через API:
     ```bash
     curl -X PUT http://localhost:8000/api/servers/$SERVER_ID \
       -H "Authorization: Bearer $TOKEN" \
       -H "Content-Type: application/json" \
       -d '{"ssh_password": null}'
     ```

### Настройка файрвола

После добавления сервера настройте файрвол для порта WireGuard:

```bash
ssh root@45.12.132.94 "ufw allow 51820/udp"
```

### Мониторинг

После добавления сервера рекомендуется:
1. Настроить мониторинг состояния сервера
2. Настроить автоматическую проверку здоровья
3. Настроить уведомления о проблемах

## Проверка результата

После добавления сервера проверьте:

1. **Список серверов:**
   ```bash
   curl -X GET http://localhost:8000/api/servers \
     -H "Authorization: Bearer $TOKEN"
   ```

2. **Информация о сервере:**
   ```bash
   curl -X GET http://localhost:8000/api/servers/$SERVER_ID \
     -H "Authorization: Bearer $TOKEN"
   ```

3. **Тестирование подключения:**
   ```bash
   curl -X POST http://localhost:8000/api/servers/$SERVER_ID/test-connection \
     -H "Authorization: Bearer $TOKEN"
   ```

## Следующие шаги

1. ✅ Добавить сервер в БД
2. ✅ Настроить SSH ключи
3. ✅ Удалить пароль из конфигурации
4. ✅ Настроить файрвол
5. ✅ Протестировать VPN подключение с мобильного приложения
6. ✅ Настроить мониторинг







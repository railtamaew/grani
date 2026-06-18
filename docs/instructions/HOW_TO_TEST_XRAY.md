# Как подключиться к XRay для тестирования

## Способ 1: Через тестовый скрипт (рекомендуется)

### Шаг 1: Запустите тестовый скрипт

```bash
cd /opt/grani/backend
python3 scripts/vpn_tester.py
```

### Шаг 2: В меню выберите:

1. **`1. Получить токен`** - если еще не получили
2. **`2. Получить список серверов`** - посмотрите доступные серверы
3. **`3. Подключиться к VPN`** - выберите этот пункт

### Шаг 3: При подключении:

- Введите **ID сервера**: `1` (для сервера 45.12.132.94)
- Введите **протокол**: `xray_vless` или `xray_vmess`

### Пример:

```
Выберите действие: 3
Введите ID сервера: 1
Введите протокол [wireguard]: xray_vless
```

## Способ 2: Через API напрямую

### Используя curl:

```bash
# 1. Получите токен (если еще нет)
TOKEN=$(python3 -c "
import sys
sys.path.insert(0, '/opt/grani/backend')
from core.database import SessionLocal
from services.auth_service import AuthService
from sqlalchemy import text
db = SessionLocal()
result = db.execute(text('SELECT id FROM users WHERE email = :email'), {'email': 'rail.tamaew@gmail.com'})
user_id = result.fetchone()[0]
token = AuthService.create_access_token(user_id)
print(token)
db.close()
")

# 2. Подключитесь через XRay
curl -X POST http://localhost:8000/api/vpn/connect \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "server_id": 1,
    "device_id": "cursor-vpn-tester-root",
    "protocol": "xray_vless"
  }'
```

## Способ 3: Через Python скрипт

Создайте файл `test_xray_connection.py`:

```python
#!/usr/bin/env python3
import sys
import os
sys.path.insert(0, '/opt/grani/backend')

from core.database import SessionLocal
from services.auth_service import AuthService
from sqlalchemy import text
import requests

# Получаем токен
db = SessionLocal()
result = db.execute(text("SELECT id FROM users WHERE email = :email"), {"email": "rail.tamaew@gmail.com"})
user_id = result.fetchone()[0]
token = AuthService.create_access_token(user_id)
db.close()

# Подключаемся через XRay
response = requests.post(
    "http://localhost:8000/api/vpn/connect",
    headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    },
    json={
        "server_id": 1,
        "device_id": "cursor-vpn-tester-root",
        "protocol": "xray_vless"  # или "xray_vmess"
    }
)

print(f"Статус: {response.status_code}")
print(f"Ответ: {response.json()}")
```

Запустите:
```bash
python3 test_xray_connection.py
```

## Способ 4: Через мобильное приложение

В мобильном приложении:
1. Выберите сервер **45.12.132.94**
2. Выберите протокол **XRay VLESS** или **XRay VMESS**
3. Подключитесь

## Что вы получите

После успешного подключения вы получите конфигурацию XRay в формате JSON или URI (vless://...), которую можно использовать в клиенте XRay.

### Пример конфигурации XRay:

```json
{
  "client_id": "uuid-клиента",
  "server": "45.12.132.94",
  "port": 4443,
  "protocol": "vless",
  "config": "..."
}
```

## Проверка подключения

После подключения проверьте:

1. **Статус подключения:**
   ```bash
   python3 scripts/vpn_tester.py
   # Выберите: 4. Проверить статус
   ```

2. **Использование XRay клиента:**
   - Скачайте клиент XRay для вашей ОС
   - Импортируйте полученную конфигурацию
   - Подключитесь

## Быстрый тест

Самый простой способ:

```bash
cd /opt/grani/backend
python3 scripts/vpn_tester.py
```

Затем:
1. `1` - Получить токен
2. `3` - Подключиться к VPN
3. Введите: `1` (ID сервера)
4. Введите: `xray_vless` (протокол)

## Важно

- **Протокол:** Используйте `xray_vless` или `xray_vmess`
- **Сервер:** ID = 1 (45.12.132.94)
- **Порт:** 4443 (уже настроен)

## Если возникнут проблемы

1. Проверьте, что XRay запущен на сервере:
   ```bash
   ssh root@45.12.132.94 "systemctl status xray"
   ```

2. Проверьте порт:
   ```bash
   ssh root@45.12.132.94 "ss -tlnp | grep 4443"
   ```

3. Проверьте логи:
   ```bash
   ssh root@45.12.132.94 "journalctl -u xray -n 20"
   ```


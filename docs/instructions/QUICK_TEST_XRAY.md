# Быстрый тест XRay подключения

## Проблема

При попытке подключиться через XRay возникает ошибка: "Не удалось создать VLESS клиента на удаленном сервере"

## Что сделано

1. ✅ XRay установлен на сервере 45.12.132.94
2. ✅ XRay настроен на порту 4443
3. ✅ Конфигурация XRay создана
4. ✅ Путь к конфигурации исправлен: `/usr/local/etc/xray/config.json`
5. ✅ Добавлена поддержка пароля для SSH

## Как протестировать вручную

### Вариант 1: Через интерактивный скрипт

```bash
cd /opt/grani/backend
python3 scripts/vpn_tester.py
```

1. Выберите `5` - Отключиться (если подключены)
2. Выберите `3` - Подключиться
3. Введите: `1` (ID сервера)
4. Введите: `xray_vless` (протокол)

### Вариант 2: Через API напрямую

```bash
# Получите токен
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

# Отключитесь
curl -X POST "http://localhost:8000/api/vpn/disconnect?device_id=cursor-vpn-tester-root" \
  -H "Authorization: Bearer $TOKEN"

# Подключитесь через XRay
curl -X POST "http://localhost:8000/api/vpn/connect" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "server_id": 1,
    "device_id": "cursor-vpn-tester-root",
    "protocol": "xray_vless"
  }'
```

## Проверка на сервере

```bash
# Проверьте статус XRay
ssh root@45.12.132.94 "systemctl status xray"

# Проверьте конфигурацию
ssh root@45.12.132.94 "cat /usr/local/etc/xray/config.json | python3 -m json.tool"

# Проверьте порт
ssh root@45.12.132.94 "ss -tlnp | grep 4443"
```

## Возможные проблемы

1. **SSH не работает** - проверьте доступ по SSH
2. **Конфигурация не читается** - проверьте путь `/usr/local/etc/xray/config.json`
3. **XRay не перезагружается** - проверьте права доступа

## Следующие шаги

Если проблема сохраняется, проверьте логи бэкенда для деталей ошибки.


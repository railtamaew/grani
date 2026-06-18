# Инструкция по настройке серверов с новыми протоколами

## Обзор протоколов

Реализованы три новых протокола:
1. **GRANIWG** - обфусцированный WireGuard
2. **XRay Reality** - максимальная защита с маскировкой под реальный сайт
3. **OpenVPN over Cloak** - связка OpenVPN + Cloak для максимальной защиты

## Настройка через базу данных

### 1. GRANIWG (обфусцированный WireGuard)

```sql
-- Включить GRANIWG на сервере
UPDATE servers 
SET 
    graniwg_enabled = true,
    graniwg_obfuscation_key = 'ваш_ключ_обфускации',
    graniwg_obfuscation_type = 'udp2raw',
    supported_protocols = JSON_ARRAY_APPEND(
        COALESCE(supported_protocols, JSON_ARRAY('wireguard')), 
        '$', 
        'graniwg'
    )
WHERE id = <server_id>;
```

**Параметры:**
- `graniwg_obfuscation_key` - ключ для обфускации трафика
- `graniwg_obfuscation_type` - тип обфускации (например, "udp2raw", "obfsproxy")

### 2. XRay Reality

```sql
-- Включить REALITY на сервере
UPDATE servers 
SET 
    reality_enabled = true,
    reality_short_id = '6ba85179e30d4fc2',  -- Генерируется автоматически
    reality_server_name = 'google.com',      -- Сайт для маскировки
    reality_dest = 'google.com:443',         -- Dest для REALITY
    reality_sni = 'google.com',              -- SNI для REALITY
    reality_private_key = 'приватный_ключ',  -- Генерируется автоматически
    reality_public_key = 'публичный_ключ',   -- Генерируется автоматически
    supported_protocols = JSON_ARRAY_APPEND(
        COALESCE(supported_protocols, JSON_ARRAY('wireguard')), 
        '$', 
        'xray_reality'
    )
WHERE id = <server_id>;
```

**Генерация ключей REALITY:**
```bash
# На сервере с Xray установленным
xray x25519
# Вывод:
# Private key: <приватный_ключ>
# Public key: <публичный_ключ>
```

**Параметры:**
- `reality_short_id` - короткий ID (можно сгенерировать случайно)
- `reality_server_name` - имя сайта для маскировки (например, "google.com", "microsoft.com")
- `reality_dest` - адрес и порт для маскировки (например, "google.com:443")
- `reality_sni` - SNI для TLS (обычно совпадает с server_name)

### 3. OpenVPN over Cloak

```sql
-- Включить OpenVPN over Cloak на сервере
UPDATE servers 
SET 
    cloak_enabled = true,
    cloak_uid = 'UID_для_Cloak',            -- Генерируется автоматически
    cloak_public_key = 'публичный_ключ',    -- Генерируется автоматически
    cloak_private_key = 'приватный_ключ',   -- Генерируется автоматически
    cloak_mask_site = 'google.com',         -- Сайт для маскировки
    cloak_admin_uid = 'admin_uid',          -- Admin UID для управления
    cloak_bypass_uid = 'bypass_uid',        -- Bypass UID
    openvpn_port = 1194,                     -- Порт OpenVPN
    supported_protocols = JSON_ARRAY_APPEND(
        COALESCE(supported_protocols, JSON_ARRAY('wireguard')), 
        '$', 
        'openvpn_cloak'
    )
WHERE id = <server_id>;
```

**Генерация ключей Cloak:**
```bash
# На сервере с Cloak установленным
ck-server -key
# Вывод:
# Private key: <приватный_ключ>
# Public key: <публичный_ключ>
```

**Генерация UID для Cloak:**
```bash
# Генерация UID
ck-server -uid
# Вывод:
# UID: <uid>
```

## Настройка через Python скрипт

Создайте файл `setup_server_protocols.py`:

```python
#!/usr/bin/env python3
"""
Скрипт для настройки протоколов на серверах
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'backend'))

from sqlalchemy.orm import Session
from core.database import SessionLocal, engine
from models.server import Server
import json

def setup_graniwg(server_id: int, obfuscation_key: str, obfuscation_type: str = "udp2raw"):
    """Настраивает GRANIWG на сервере"""
    db = SessionLocal()
    try:
        server = db.query(Server).filter(Server.id == server_id).first()
        if not server:
            print(f"Сервер {server_id} не найден")
            return False
        
        server.graniwg_enabled = True
        server.graniwg_obfuscation_key = obfuscation_key
        server.graniwg_obfuscation_type = obfuscation_type
        
        # Обновляем supported_protocols
        protocols = server.get_supported_protocols()
        if 'graniwg' not in protocols:
            protocols.append('graniwg')
        server.set_supported_protocols(protocols)
        
        db.commit()
        print(f"GRANIWG настроен на сервере {server_id}")
        return True
    except Exception as e:
        print(f"Ошибка настройки GRANIWG: {e}")
        db.rollback()
        return False
    finally:
        db.close()

def setup_reality(server_id: int, server_name: str = "google.com", dest: str = "google.com:443"):
    """Настраивает XRay Reality на сервере"""
    db = SessionLocal()
    try:
        server = db.query(Server).filter(Server.id == server_id).first()
        if not server:
            print(f"Сервер {server_id} не найден")
            return False
        
        # Генерируем ключи (в реальности нужно использовать xray x25519)
        import secrets
        import base64
        
        # Генерируем short_id (8 байт в hex)
        short_id = secrets.token_hex(8)
        
        # В реальности нужно запустить: xray x25519
        # Здесь заглушка
        private_key = "замените_на_реальный_приватный_ключ"
        public_key = "замените_на_реальный_публичный_ключ"
        
        server.reality_enabled = True
        server.reality_short_id = short_id
        server.reality_server_name = server_name
        server.reality_dest = dest
        server.reality_sni = server_name
        server.reality_private_key = private_key
        server.reality_public_key = public_key
        
        # Обновляем supported_protocols
        protocols = server.get_supported_protocols()
        if 'xray_reality' not in protocols:
            protocols.append('xray_reality')
        server.set_supported_protocols(protocols)
        
        db.commit()
        print(f"XRay Reality настроен на сервере {server_id}")
        print(f"Short ID: {short_id}")
        print(f"Server Name: {server_name}")
        return True
    except Exception as e:
        print(f"Ошибка настройки REALITY: {e}")
        db.rollback()
        return False
    finally:
        db.close()

def setup_openvpn_cloak(server_id: int, mask_site: str = "google.com", port: int = 1194):
    """Настраивает OpenVPN over Cloak на сервере"""
    db = SessionLocal()
    try:
        server = db.query(Server).filter(Server.id == server_id).first()
        if not server:
            print(f"Сервер {server_id} не найден")
            return False
        
        # Генерируем UID и ключи (в реальности нужно использовать ck-server)
        import secrets
        
        # Генерируем UID
        uid = secrets.token_hex(16)
        admin_uid = secrets.token_hex(16)
        bypass_uid = secrets.token_hex(16)
        
        # В реальности нужно запустить: ck-server -key
        # Здесь заглушка
        private_key = "замените_на_реальный_приватный_ключ"
        public_key = "замените_на_реальный_публичный_ключ"
        
        server.cloak_enabled = True
        server.cloak_uid = uid
        server.cloak_public_key = public_key
        server.cloak_private_key = private_key
        server.cloak_mask_site = mask_site
        server.cloak_admin_uid = admin_uid
        server.cloak_bypass_uid = bypass_uid
        server.openvpn_port = port
        
        # Обновляем supported_protocols
        protocols = server.get_supported_protocols()
        if 'openvpn_cloak' not in protocols:
            protocols.append('openvpn_cloak')
        server.set_supported_protocols(protocols)
        
        db.commit()
        print(f"OpenVPN over Cloak настроен на сервере {server_id}")
        print(f"UID: {uid}")
        print(f"Mask Site: {mask_site}")
        return True
    except Exception as e:
        print(f"Ошибка настройки OpenVPN over Cloak: {e}")
        db.rollback()
        return False
    finally:
        db.close()

if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description='Настройка протоколов на серверах')
    parser.add_argument('protocol', choices=['graniwg', 'reality', 'openvpn_cloak'], help='Протокол для настройки')
    parser.add_argument('server_id', type=int, help='ID сервера')
    parser.add_argument('--key', help='Ключ обфускации для GRANIWG')
    parser.add_argument('--server-name', default='google.com', help='Имя сервера для маскировки (REALITY/Cloak)')
    parser.add_argument('--dest', default='google.com:443', help='Dest для REALITY')
    parser.add_argument('--port', type=int, default=1194, help='Порт для OpenVPN')
    
    args = parser.parse_args()
    
    if args.protocol == 'graniwg':
        if not args.key:
            print("Ошибка: требуется --key для GRANIWG")
            sys.exit(1)
        setup_graniwg(args.server_id, args.key)
    elif args.protocol == 'reality':
        setup_reality(args.server_id, args.server_name, args.dest)
    elif args.protocol == 'openvpn_cloak':
        setup_openvpn_cloak(args.server_id, args.server_name, args.port)
```

## Примеры использования

### Настройка GRANIWG:
```bash
python3 setup_server_protocols.py graniwg 1 --key "my_obfuscation_key_12345"
```

### Настройка XRay Reality:
```bash
python3 setup_server_protocols.py reality 1 --server-name "google.com" --dest "google.com:443"
```

### Настройка OpenVPN over Cloak:
```bash
python3 setup_server_protocols.py openvpn_cloak 1 --server-name "google.com" --port 1194
```

## Важные замечания

1. **REALITY ключи**: Должны быть сгенерированы командой `xray x25519` на сервере
2. **Cloak ключи**: Должны быть сгенерированы командой `ck-server -key` на сервере
3. **Маскировка сайтов**: Выбирайте популярные сайты (google.com, microsoft.com, cloudflare.com) для лучшей маскировки
4. **Порты**: Убедитесь, что порты открыты в firewall
5. **Миграция БД**: После добавления новых полей в модель Server, выполните миграцию Alembic

## Миграция базы данных

После добавления новых полей нужно создать миграцию:

```bash
cd backend
alembic revision --autogenerate -m "Add new VPN protocols support"
alembic upgrade head
```

## Проверка настроек

После настройки проверьте через API:

```bash
# Получить список серверов с протоколами
curl -H "Authorization: Bearer YOUR_TOKEN" http://localhost:8000/api/vpn/servers
```

В ответе должно быть поле `supported_protocols` с новыми протоколами.



#!/usr/bin/env python3
"""
Скрипт для настройки протоколов на серверах
"""
import sys
import os
import secrets

# Добавляем путь к backend
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from sqlalchemy.orm import Session
from core.database import SessionLocal
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
        print(f"✅ GRANIWG настроен на сервере {server_id}")
        print(f"   Obfuscation Key: {obfuscation_key[:20]}...")
        print(f"   Obfuscation Type: {obfuscation_type}")
        return True
    except Exception as e:
        print(f"❌ Ошибка настройки GRANIWG: {e}")
        db.rollback()
        return False
    finally:
        db.close()

def setup_reality(server_id: int, server_name: str = "google.com", dest: str = "google.com:443", 
                  private_key: str = None, public_key: str = None):
    """Настраивает XRay Reality на сервере"""
    db = SessionLocal()
    try:
        server = db.query(Server).filter(Server.id == server_id).first()
        if not server:
            print(f"Сервер {server_id} не найден")
            return False
        
        # Генерируем short_id (8 байт в hex)
        short_id = secrets.token_hex(8)
        
        # Если ключи не предоставлены, генерируем заглушку
        if not private_key:
            private_key = f"REPLACE_WITH_REAL_PRIVATE_KEY_{secrets.token_hex(16)}"
            print("⚠️  ВНИМАНИЕ: Используется заглушка для приватного ключа!")
            print("   Сгенерируйте реальные ключи командой: xray x25519")
        
        if not public_key:
            public_key = f"REPLACE_WITH_REAL_PUBLIC_KEY_{secrets.token_hex(16)}"
            print("⚠️  ВНИМАНИЕ: Используется заглушка для публичного ключа!")
            print("   Сгенерируйте реальные ключи командой: xray x25519")
        
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
        print(f"✅ XRay Reality настроен на сервере {server_id}")
        print(f"   Short ID: {short_id}")
        print(f"   Server Name: {server_name}")
        print(f"   Dest: {dest}")
        print(f"   Public Key: {public_key[:30]}...")
        return True
    except Exception as e:
        print(f"❌ Ошибка настройки REALITY: {e}")
        db.rollback()
        return False
    finally:
        db.close()

def setup_openvpn_cloak(server_id: int, mask_site: str = "google.com", port: int = 1194,
                        private_key: str = None, public_key: str = None):
    """Настраивает OpenVPN over Cloak на сервере"""
    db = SessionLocal()
    try:
        server = db.query(Server).filter(Server.id == server_id).first()
        if not server:
            print(f"Сервер {server_id} не найден")
            return False
        
        # Генерируем UID
        uid = secrets.token_hex(16)
        admin_uid = secrets.token_hex(16)
        bypass_uid = secrets.token_hex(16)
        
        # Если ключи не предоставлены, генерируем заглушку
        if not private_key:
            private_key = f"REPLACE_WITH_REAL_PRIVATE_KEY_{secrets.token_hex(16)}"
            print("⚠️  ВНИМАНИЕ: Используется заглушка для приватного ключа!")
            print("   Сгенерируйте реальные ключи командой: ck-server -key")
        
        if not public_key:
            public_key = f"REPLACE_WITH_REAL_PUBLIC_KEY_{secrets.token_hex(16)}"
            print("⚠️  ВНИМАНИЕ: Используется заглушка для публичного ключа!")
            print("   Сгенерируйте реальные ключи командой: ck-server -key")
        
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
        print(f"✅ OpenVPN over Cloak настроен на сервере {server_id}")
        print(f"   UID: {uid}")
        print(f"   Mask Site: {mask_site}")
        print(f"   Port: {port}")
        print(f"   Public Key: {public_key[:30]}...")
        return True
    except Exception as e:
        print(f"❌ Ошибка настройки OpenVPN over Cloak: {e}")
        db.rollback()
        return False
    finally:
        db.close()

def list_servers():
    """Выводит список всех серверов"""
    db = SessionLocal()
    try:
        servers = db.query(Server).all()
        print("\n📋 Список серверов:")
        print("-" * 80)
        for server in servers:
            protocols = server.get_supported_protocols()
            print(f"ID: {server.id} | {server.name} ({server.country})")
            print(f"   IP: {server.ip_address}")
            print(f"   Протоколы: {', '.join(protocols)}")
            print(f"   GRANIWG: {'✅' if server.graniwg_enabled else '❌'}")
            print(f"   REALITY: {'✅' if server.reality_enabled else '❌'}")
            print(f"   OpenVPN Cloak: {'✅' if server.cloak_enabled else '❌'}")
            print("-" * 80)
    finally:
        db.close()

if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description='Настройка протоколов на серверах')
    subparsers = parser.add_subparsers(dest='command', help='Команда')
    
    # Команда list
    list_parser = subparsers.add_parser('list', help='Показать список серверов')
    
    # Команда graniwg
    graniwg_parser = subparsers.add_parser('graniwg', help='Настроить GRANIWG')
    graniwg_parser.add_argument('server_id', type=int, help='ID сервера')
    graniwg_parser.add_argument('--key', required=True, help='Ключ обфускации')
    graniwg_parser.add_argument('--type', default='udp2raw', help='Тип обфускации (по умолчанию: udp2raw)')
    
    # Команда reality
    reality_parser = subparsers.add_parser('reality', help='Настроить XRay Reality')
    reality_parser.add_argument('server_id', type=int, help='ID сервера')
    reality_parser.add_argument('--server-name', default='google.com', help='Имя сервера для маскировки')
    reality_parser.add_argument('--dest', default='google.com:443', help='Dest для REALITY')
    reality_parser.add_argument('--private-key', help='Приватный ключ (если не указан, будет заглушка)')
    reality_parser.add_argument('--public-key', help='Публичный ключ (если не указан, будет заглушка)')
    
    # Команда openvpn-cloak
    cloak_parser = subparsers.add_parser('openvpn-cloak', help='Настроить OpenVPN over Cloak')
    cloak_parser.add_argument('server_id', type=int, help='ID сервера')
    cloak_parser.add_argument('--mask-site', default='google.com', help='Сайт для маскировки')
    cloak_parser.add_argument('--port', type=int, default=1194, help='Порт OpenVPN')
    cloak_parser.add_argument('--private-key', help='Приватный ключ Cloak (если не указан, будет заглушка)')
    cloak_parser.add_argument('--public-key', help='Публичный ключ Cloak (если не указан, будет заглушка)')
    
    args = parser.parse_args()
    
    if args.command == 'list':
        list_servers()
    elif args.command == 'graniwg':
        setup_graniwg(args.server_id, args.key, args.type)
    elif args.command == 'reality':
        setup_reality(args.server_id, args.server_name, args.dest, args.private_key, args.public_key)
    elif args.command == 'openvpn-cloak':
        setup_openvpn_cloak(args.server_id, args.mask_site, args.port, args.private_key, args.public_key)
    else:
        parser.print_help()



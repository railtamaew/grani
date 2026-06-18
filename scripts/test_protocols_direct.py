#!/usr/bin/env python3
"""
Прямое тестирование протоколов через backend код (без API)

Тестирует создание конфигураций для всех протоколов напрямую через менеджеры.
"""
import sys
import os
from pathlib import Path

# Добавляем путь к backend
sys.path.insert(0, str(Path(__file__).parent.parent / "backend"))

from sqlalchemy import text
from core.database import SessionLocal
from models.server import Server
from models.user import Device, User
from services.wireguard_manager import WireGuardManager
from services.xray_manager import XrayManager
import json

def test_wireguard_protocol():
    """Тестирует создание WireGuard конфигурации"""
    print("🔌 Тестирование WireGuard протокола...")
    
    db = SessionLocal()
    try:
        # Получаем первый активный сервер
        conn = db.connection()
        result = conn.execute(text("""
            SELECT id, name, ip_address, wireguard_public_key, wireguard_port
            FROM servers 
            WHERE is_active = true AND wireguard_public_key IS NOT NULL
            LIMIT 1
        """))
        
        server = result.fetchone()
        if not server:
            print("   ⚠️  Нет серверов с WireGuard")
            return False
        
        server_id, name, ip_address, public_key, port = server
        
        print(f"   Сервер: {name} ({ip_address})")
        
        # Создаем менеджер
        manager = WireGuardManager()
        
        # Получаем объект сервера для менеджера
        server_obj = db.query(Server).filter(Server.id == server_id).first()
        if not server_obj:
            print("   ❌ Сервер не найден")
            return False
        
        # Получаем или создаем тестовое устройство
        user = db.query(User).filter(User.email == "rail.tamaew@gmail.com").first()
        if not user:
            print("   ⚠️  Пользователь не найден")
            return False
        
        device = db.query(Device).filter(Device.device_id == "test-device-wg").first()
        if not device:
            device = Device(
                device_id="test-device-wg",
                platform="android",
                user_id=user.id
            )
            db.add(device)
            db.commit()
            db.refresh(device)
        
        # Генерируем IP для клиента
        manager = WireGuardManager()
        client_ip = manager.get_next_available_ip(server_obj)
        
        # Генерируем конфигурацию
        try:
            config = manager.create_client_config(
                device=device,
                server=server_obj,
                client_ip=client_ip,
                protocol="wireguard"
            )
            
            if config and '[Interface]' in config and '[Peer]' in config:
                print(f"   ✅ WireGuard конфигурация создана (длина: {len(config)})")
                return True
            else:
                print(f"   ❌ Неверный формат конфигурации")
                return False
        except Exception as e:
            print(f"   ❌ Ошибка создания конфигурации: {e}")
            return False
            
    except Exception as e:
        print(f"   ❌ Ошибка: {e}")
        return False
    finally:
        db.close()

def test_xray_protocol(protocol: str):
    """Тестирует создание XRay конфигурации"""
    print(f"🔌 Тестирование XRay протокола: {protocol}...")
    
    db = SessionLocal()
    try:
        # Получаем объект сервера
        server_obj = db.query(Server).filter(Server.is_active == True).first()
        
        if not server_obj:
            print("   ⚠️  Нет активных серверов")
            return False
        
        print(f"   Сервер: {server_obj.name} ({server_obj.ip_address})")
        
        # Получаем или создаем тестовое устройство
        user = db.query(User).filter(User.email == "rail.tamaew@gmail.com").first()
        if not user:
            print("   ⚠️  Пользователь не найден")
            return False
        
        device_id_str = f"test-device-{protocol}"
        device = db.query(Device).filter(Device.device_id == device_id_str).first()
        if not device:
            device = Device(
                device_id=device_id_str,
                platform="android",
                user_id=user.id
            )
            db.add(device)
            db.commit()
            db.refresh(device)
        
        # Создаем менеджер
        manager = XrayManager(server=server_obj)
        
        # Создаем клиента в зависимости от протокола
        try:
            if protocol == "xray_vless":
                client_data = manager.create_vless_client(device, server_obj)
            elif protocol == "xray_vmess":
                client_data = manager.create_vmess_client(device, server_obj)
            elif protocol == "xray_reality":
                client_data = manager.create_reality_client(device, server_obj)
            else:
                print(f"   ❌ Неизвестный протокол: {protocol}")
                return False
            
            if client_data and client_data.get('success'):
                print(f"   ✅ XRay клиент создан: {client_data.get('client_id', 'N/A')}")
                
                # Проверяем наличие конфигурации
                config = client_data.get('config') or client_data.get('json_config')
                if config:
                    print(f"   ✅ Конфигурация получена (длина: {len(str(config))})")
                    return True
                else:
                    print(f"   ⚠️  Конфигурация отсутствует в ответе")
                    return False
            else:
                error = client_data.get('error', 'Unknown error') if client_data else 'No response'
                print(f"   ❌ Не удалось создать клиента: {error}")
                return False
        except Exception as e:
            print(f"   ❌ Ошибка создания клиента: {e}")
            import traceback
            traceback.print_exc()
            return False
            
    except Exception as e:
        print(f"   ❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False
    finally:
        db.close()

def main():
    """Запускает тестирование всех протоколов"""
    print("🚀 Прямое тестирование протоколов VPN...")
    print("=" * 70)
    print()
    
    results = []
    
    # Тестируем WireGuard
    print("📋 1. WireGuard")
    print("-" * 70)
    success = test_wireguard_protocol()
    results.append(("WireGuard", success))
    print()
    
    # Тестируем XRay протоколы
    xray_protocols = ["xray_vless", "xray_vmess", "xray_reality"]
    
    for i, protocol in enumerate(xray_protocols, start=2):
        print(f"📋 {i}. {protocol}")
        print("-" * 70)
        success = test_xray_protocol(protocol)
        results.append((protocol, success))
        print()
    
    # Итоговый отчет
    print("=" * 70)
    print("📊 ИТОГОВЫЙ РЕЗУЛЬТАТ:")
    print("-" * 70)
    
    successful = sum(1 for _, success in results if success)
    total = len(results)
    
    for protocol, success in results:
        status = "✅" if success else "❌"
        print(f"   {status} {protocol}")
    
    print(f"\n   Успешно: {successful}/{total}")
    
    if successful == total:
        print("\n✅ Все протоколы работают корректно!")
        return 0
    else:
        print(f"\n⚠️  {total - successful} протоколов не удалось протестировать")
        return 1

if __name__ == "__main__":
    sys.exit(main())

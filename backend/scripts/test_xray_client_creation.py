#!/usr/bin/env python3
"""
Скрипт для тестирования создания Xray клиента
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from sqlalchemy import text
from core.database import engine
from services.remote_vpn_manager import RemoteVPNManager
from services.xray_manager import XrayManager
from services.auth_service import AuthService
import json
import requests

# Простой класс для представления сервера и устройства
class ServerProxy:
    def __init__(self, data):
        for key, value in data.items():
            setattr(self, key, value)
    
    def get_supported_protocols(self):
        if self.supported_protocols:
            if isinstance(self.supported_protocols, str):
                return json.loads(self.supported_protocols)
            return self.supported_protocols
        return ["wireguard"]

class DeviceProxy:
    def __init__(self, data):
        for key, value in data.items():
            setattr(self, key, value)

def get_test_user_and_device():
    """Получает тестового пользователя и устройство"""
    try:
        with engine.connect() as conn:
            # Получаем пользователя, у которого есть устройства
            result = conn.execute(text("""
                SELECT d.id, d.device_id, d.user_id, d.device_name, u.email
                FROM devices d
                JOIN users u ON d.user_id = u.id
                WHERE u.is_active = true
                LIMIT 1
            """))
            row = result.fetchone()
            
            if not row:
                print("❌ Не найдено устройств в базе данных")
                print("   Нужно зарегистрировать устройство через API /vpn/device/register")
                return None, None
            
            device_data = {
                'id': row[0],
                'device_id': row[1],
                'user_id': row[2],
                'device_name': row[3]
            }
            
            device = DeviceProxy(device_data)
            user_email = row[4]
            print(f"✅ Пользователь: {user_email} (ID: {device.user_id})")
            print(f"✅ Устройство: {device.device_id} (ID: {device.id})")
            
            return device.user_id, device
            
    except Exception as e:
        print(f"❌ Ошибка получения пользователя/устройства: {e}")
        import traceback
        traceback.print_exc()
        return None, None

def get_server():
    """Получает сервер 45.12.132.94"""
    try:
        with engine.connect() as conn:
            result = conn.execute(text("""
                SELECT id, name, ip_address, xray_port, xray_config_path, 
                       supported_protocols, ssh_host, ssh_port, ssh_user,
                       ssh_key_path, ssh_key_content, ssh_password,
                       reality_enabled, reality_public_key, reality_private_key,
                       reality_short_id, reality_sni, reality_dest
                FROM servers 
                WHERE ip_address = :ip
                LIMIT 1
            """), {"ip": "45.12.132.94"})
            
            row = result.fetchone()
            
            if not row:
                return None
            
            server_data = {
                'id': row[0],
                'name': row[1],
                'ip_address': row[2],
                'xray_port': row[3],
                'xray_config_path': row[4],
                'supported_protocols': row[5],
                'ssh_host': row[6],
                'ssh_port': row[7],
                'ssh_user': row[8],
                'ssh_key_path': row[9],
                'ssh_key_content': row[10],
                'ssh_password': row[11],  # Загружаем пароль из БД
                'reality_enabled': row[12],
                'reality_public_key': row[13],
                'reality_private_key': row[14],  # Добавляем приватный ключ
                'reality_short_id': row[15],
                'reality_sni': row[16],
                'reality_dest': row[17],
                'is_local': False
            }
            
            return ServerProxy(server_data)
            
    except Exception as e:
        print(f"❌ Ошибка получения сервера: {e}")
        import traceback
        traceback.print_exc()
        return None

def test_create_vless_client(server, device):
    """Тестирует создание VLESS клиента"""
    print("\n" + "="*60)
    print("  ТЕСТ СОЗДАНИЯ VLESS КЛИЕНТА")
    print("="*60 + "\n")
    
    xm = XrayManager()
    
    if not xm.remote_manager or not xm.remote_manager.ssh_manager:
        print("❌ XrayManager или SSHManager недоступен")
        return False
    
    try:
        print(f"Создание VLESS клиента для устройства {device.device_id}...")
        result = xm.create_vless_client(device, server)
        
        if result.get('success'):
            print("✅ VLESS клиент успешно создан!")
            print(f"   Client ID: {result.get('client_id')}")
            print(f"   UUID: {result.get('uuid')}")
            print(f"   Config URL: {result.get('config')[:80]}..." if result.get('config') else "   Config: не сгенерирован")
            print(f"   IP: {result.get('ip_address')}")
            return True
        else:
            print(f"❌ Ошибка создания клиента: {result.get('error')}")
            return False
            
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False

def test_create_vmess_client(server, device):
    """Тестирует создание VMESS клиента"""
    print("\n" + "="*60)
    print("  ТЕСТ СОЗДАНИЯ VMESS КЛИЕНТА")
    print("="*60 + "\n")
    
    xm = XrayManager()
    
    try:
        print(f"Создание VMESS клиента для устройства {device.device_id}...")
        result = xm.create_vmess_client(device, server)
        
        if result.get('success'):
            print("✅ VMESS клиент успешно создан!")
            print(f"   Client ID: {result.get('client_id')}")
            print(f"   UUID: {result.get('uuid')}")
            print(f"   Config URL: {result.get('config')[:80]}..." if result.get('config') else "   Config: не сгенерирован")
            return True
        else:
            print(f"❌ Ошибка создания клиента: {result.get('error')}")
            return False
            
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False

def test_create_reality_client(server, device):
    """Тестирует создание REALITY клиента"""
    print("\n" + "="*60)
    print("  ТЕСТ СОЗДАНИЯ REALITY КЛИЕНТА")
    print("="*60 + "\n")
    
    xm = XrayManager()
    
    try:
        print(f"Создание REALITY клиента для устройства {device.device_id}...")
        result = xm.create_reality_client(device, server)
        
        if result.get('success'):
            print("✅ REALITY клиент успешно создан!")
            print(f"   Client ID: {result.get('client_id')}")
            print(f"   UUID: {result.get('uuid')}")
            print(f"   Config URL: {result.get('config')[:80]}..." if result.get('config') else "   Config: не сгенерирован")
            return True
        else:
            print(f"❌ Ошибка создания клиента: {result.get('error')}")
            return False
            
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False

def main():
    """Основная функция"""
    print("\n" + "="*60)
    print("  ТЕСТИРОВАНИЕ СОЗДАНИЯ XRAY КЛИЕНТОВ")
    print("="*60)
    
    # Получаем сервер
    server = get_server()
    if not server:
        print("❌ Сервер 45.12.132.94 не найден")
        return False
    
    # Получаем пользователя и устройство
    user_id, device = get_test_user_and_device()
    if not user_id:
        print("❌ Не удалось получить пользователя")
        return False
    
    if not device:
        print("❌ Не удалось получить устройство")
        print("   Зарегистрируйте устройство через API /vpn/device/register")
        return False
    
    # Тестируем создание клиентов
    results = []
    
    # 1. VLESS
    results.append(("VLESS", test_create_vless_client(server, device)))
    
    # 2. VMESS
    results.append(("VMESS", test_create_vmess_client(server, device)))
    
    # 3. REALITY
    if server.reality_enabled:
        results.append(("REALITY", test_create_reality_client(server, device)))
    else:
        print("\n⚠️  REALITY не включен на сервере, пропускаем тест")
        results.append(("REALITY", None))
    
    # Итоговый результат
    print("\n" + "="*60)
    print("  ИТОГОВЫЙ РЕЗУЛЬТАТ")
    print("="*60 + "\n")
    
    for protocol, success in results:
        if success is None:
            status = "⏭️  Пропущен"
        elif success:
            status = "✅ Успешно"
        else:
            status = "❌ Ошибка"
        print(f"{protocol:10} : {status}")
    
    all_success = all(s for _, s in results if s is not None)
    
    if all_success:
        print("\n✅ Все протоколы работают!")
        return True
    else:
        print("\n⚠️  Некоторые протоколы не работают. Проверьте логи выше.")
        return False

if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)
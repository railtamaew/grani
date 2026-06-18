#!/usr/bin/env python3
"""
Скрипт для тестирования получения статистики Xray
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from sqlalchemy import text
from core.database import engine
from services.remote_vpn_manager import RemoteVPNManager
from services.xray_manager import XrayManager
import json

# Простой класс для представления сервера
class ServerProxy:
    def __init__(self, data):
        for key, value in data.items():
            setattr(self, key, value)

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
                'ssh_password': row[11],
                'reality_enabled': row[12],
                'reality_public_key': row[13],
                'reality_private_key': row[14],
                'reality_short_id': row[15],
                'reality_sni': row[16],
                'reality_dest': row[17],
                'is_local': False
            }
            
            return ServerProxy(server_data)
            
    except Exception as e:
        print(f"❌ Ошибка получения сервера: {e}")
        return None

def main():
    """Основная функция"""
    print("\n" + "="*60)
    print("  ТЕСТИРОВАНИЕ ПОЛУЧЕНИЯ СТАТИСТИКИ XRAY")
    print("="*60 + "\n")
    
    server = get_server()
    if not server:
        print("❌ Сервер не найден")
        return False
    
    print(f"✅ Сервер найден: {server.name} (ID: {server.id})")
    
    xm = XrayManager()
    
    # Тест 1: Статистика сервера
    print("\n" + "="*60)
    print("  ТЕСТ: Статистика сервера")
    print("="*60 + "\n")
    
    try:
        stats = xm.get_server_stats(server)
        print(f"Total uplink: {stats.get('total_uplink', 0)} bytes")
        print(f"Total downlink: {stats.get('total_downlink', 0)} bytes")
        print(f"Active clients: {stats.get('active_clients', 0)}")
        print(f"Total clients: {stats.get('total_clients', 0)}")
        print(f"Timestamp: {stats.get('timestamp', 'N/A')}")
        if 'error' in stats:
            print(f"⚠️  Ошибка: {stats['error']}")
        if 'message' in stats:
            print(f"ℹ️  Сообщение: {stats['message']}")
        print("✅ Статистика сервера получена")
    except Exception as e:
        print(f"❌ Ошибка получения статистики сервера: {e}")
        import traceback
        traceback.print_exc()
    
    # Тест 2: Проверка здоровья
    print("\n" + "="*60)
    print("  ТЕСТ: Проверка здоровья")
    print("="*60 + "\n")
    
    try:
        health = xm.check_server_health(server)
        print(f"Status: {health.get('status', 'unknown')}")
        print(f"Message: {health.get('message', 'N/A')}")
        if health.get('status') == 'healthy':
            print("✅ Сервер здоров")
        else:
            print("⚠️  Проблемы с сервером")
    except Exception as e:
        print(f"❌ Ошибка проверки здоровья: {e}")
        import traceback
        traceback.print_exc()
    
    # Тест 3: Статистика клиента (если есть)
    print("\n" + "="*60)
    print("  ТЕСТ: Статистика клиента")
    print("="*60 + "\n")
    
    # Получаем первый клиент из конфигурации
    try:
        config = xm._read_xray_config(server)
        for inbound in config.get('inbounds', []):
            clients = inbound.get('settings', {}).get('clients', [])
            if clients:
                # Берем первого клиента
                client = clients[0]
                client_email = client.get('email', '')
                # Формируем client_id (примерный формат)
                if client_email:
                    parts = client_email.split('@')[0].split('_')
                    if len(parts) >= 2:
                        client_id = f"vless_{parts[1]}_{server.id}"
                        print(f"Тестируем клиента: {client_id} ({client_email})")
                        
                        client_stats = xm.get_client_stats(client_id, server)
                        print(f"Uplink: {client_stats.get('uplink', 0)} bytes")
                        print(f"Downlink: {client_stats.get('downlink', 0)} bytes")
                        if 'error' in client_stats:
                            print(f"⚠️  Ошибка: {client_stats['error']}")
                        else:
                            print("✅ Статистика клиента получена")
                        break
    except Exception as e:
        print(f"⚠️  Не удалось получить статистику клиента: {e}")
    
    print("\n" + "="*60)
    print("  ТЕСТИРОВАНИЕ ЗАВЕРШЕНО")
    print("="*60 + "\n")
    
    return True

if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)
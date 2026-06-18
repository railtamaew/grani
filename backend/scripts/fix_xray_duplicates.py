#!/usr/bin/env python3
"""
Исправление дублирующихся пользователей в конфигурации Xray
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from sqlalchemy import text
from core.database import engine
from services.remote_vpn_manager import RemoteVPNManager
from services.xray_manager import XrayManager
import json

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
                       ssh_host, ssh_port, ssh_user,
                       ssh_key_path, ssh_key_content, ssh_password
                FROM servers 
                WHERE ip_address = :ip
                LIMIT 1
            """), {"ip": "45.12.132.94"})
            
            row = result.fetchone()
            if not row:
                return None
            
            server_data = {
                'id': row[0], 'name': row[1], 'ip_address': row[2],
                'xray_port': row[3], 'xray_config_path': row[4],
                'ssh_host': row[5], 'ssh_port': row[6], 'ssh_user': row[7],
                'ssh_key_path': row[8], 'ssh_key_content': row[9],
                'ssh_password': row[10], 'is_local': False
            }
            return ServerProxy(server_data)
    except Exception as e:
        print(f"❌ Ошибка получения сервера: {e}")
        return None

def fix_duplicates(config):
    """Удаляет дублирующихся пользователей из конфигурации"""
    print("\nПоиск и удаление дубликатов...")
    
    fixed = False
    seen_emails = {}  # {email: (protocol, inbound_index)}
    
    for inbound_idx, inbound in enumerate(config.get('inbounds', [])):
        protocol = inbound.get('protocol')
        if protocol not in ['vless', 'vmess']:
            continue
        
        clients = inbound.get('settings', {}).get('clients', [])
        if not clients:
            continue
        
        unique_clients = []
        for client in clients:
            email = client.get('email', '')
            if not email:
                continue
            
            # Проверяем, есть ли дубликат
            if email in seen_emails:
                prev_protocol, prev_inbound = seen_emails[email]
                print(f"⚠️  Найден дубликат: {email}")
                print(f"   Первое вхождение: {prev_protocol} в inbound {prev_inbound}")
                print(f"   Дубликат: {protocol} в inbound {inbound_idx}")
                fixed = True
            else:
                seen_emails[email] = (protocol, inbound_idx)
                unique_clients.append(client)
        
        # Обновляем список клиентов
        inbound['settings']['clients'] = unique_clients
        print(f"   Inbound {inbound_idx} ({protocol}): {len(unique_clients)} уникальных клиентов")
    
    return fixed

def main():
    """Основная функция"""
    print("\n" + "="*60)
    print("  ИСПРАВЛЕНИЕ ДУБЛИКАТОВ В КОНФИГУРАЦИИ XRAY")
    print("="*60 + "\n")
    
    server = get_server()
    if not server:
        print("❌ Сервер не найден")
        return False
    
    xm = XrayManager()
    if not xm.remote_manager or not xm.remote_manager.ssh_manager:
        print("❌ SSH недоступен")
        return False
    
    # Читаем конфигурацию
    print("Чтение конфигурации...")
    config = xm._read_xray_config(server)
    
    # Исправляем дубликаты
    fixed = fix_duplicates(config)
    
    if not fixed:
        print("\n✅ Дубликатов не найдено")
        return True
    
    # Сохраняем исправленную конфигурацию
    print("\nСохранение исправленной конфигурации...")
    if xm._write_xray_config(server, config):
        print("✅ Конфигурация сохранена")
        
        # Перезагружаем Xray
        print("\nПерезагрузка Xray...")
        if xm._reload_xray(server):
            print("✅ Xray перезагружен")
            
            # Проверяем статус
            print("\nПроверка статуса...")
            import time
            time.sleep(2)
            
            ssh_config = xm._get_ssh_config(server)
            result = xm.remote_manager.ssh_manager.execute_command(
                ssh_config['host'],
                "systemctl is-active xray-v2",
                ssh_config['port'],
                ssh_config['username'],
                ssh_config.get('key_path'),
                ssh_config.get('key_content'),
                ssh_config.get('password')
            )
            
            if result['success'] and "active" in result['stdout']:
                print("✅ Xray успешно запущен!")
                return True
            else:
                print(f"⚠️  Xray не запущен: {result['stderr']}")
                return False
        else:
            print("⚠️  Конфигурация сохранена, но перезагрузка не удалась")
            return False
    else:
        print("❌ Не удалось сохранить конфигурацию")
        return False

if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)
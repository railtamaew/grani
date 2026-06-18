#!/usr/bin/env python3
"""
Проверка статуса Xray на сервере
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from sqlalchemy import text
from core.database import engine
from services.remote_vpn_manager import RemoteVPNManager

class ServerProxy:
    def __init__(self, data):
        for key, value in data.items():
            setattr(self, key, value)

def get_server():
    """Получает сервер 45.12.132.94"""
    try:
        with engine.connect() as conn:
            result = conn.execute(text("""
                SELECT id, name, ip_address, ssh_host, ssh_port, ssh_user,
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
                'ssh_host': row[3], 'ssh_port': row[4], 'ssh_user': row[5],
                'ssh_key_path': row[6], 'ssh_key_content': row[7],
                'ssh_password': row[8], 'is_local': False
            }
            return ServerProxy(server_data)
    except Exception as e:
        print(f"❌ Ошибка получения сервера: {e}")
        return None

def main():
    """Основная функция"""
    print("\n" + "="*60)
    print("  ПРОВЕРКА СТАТУСА XRAY")
    print("="*60 + "\n")
    
    server = get_server()
    if not server:
        print("❌ Сервер не найден")
        return False
    
    rm = RemoteVPNManager()
    if not rm.ssh_manager:
        print("❌ SSH недоступен")
        return False
    
    ssh_config = rm.get_ssh_config(server)
    
    # Проверка статуса Xray
    print("1. Проверка статуса Xray:")
    result = rm.ssh_manager.execute_command(
        ssh_config['host'],
        "systemctl status xray-v2 --no-pager | head -5",
        ssh_config['port'],
        ssh_config['username'],
        ssh_config.get('key_path'),
        ssh_config.get('key_content'),
        ssh_config.get('password')
    )
    print(result['stdout'] if result['success'] else f"Ошибка: {result['stderr']}")
    
    # Проверка порта 10085
    print("\n2. Проверка порта 10085:")
    result = rm.ssh_manager.execute_command(
        ssh_config['host'],
        "ss -tlnp | grep 10085 || netstat -tlnp 2>/dev/null | grep 10085 || echo 'Порт не найден'",
        ssh_config['port'],
        ssh_config['username'],
        ssh_config.get('key_path'),
        ssh_config.get('key_content'),
        ssh_config.get('password')
    )
    print(result['stdout'] if result['success'] else f"Ошибка: {result['stderr']}")
    
    # Проверка доступности Stats API
    print("\n3. Проверка Stats API:")
    result = rm.ssh_manager.execute_command(
        ssh_config['host'],
        "curl -s 'http://127.0.0.1:10085/stats?reset=false' 2>&1 | head -5",
        ssh_config['port'],
        ssh_config['username'],
        ssh_config.get('key_path'),
        ssh_config.get('key_content'),
        ssh_config.get('password')
    )
    if result['success'] and result['stdout']:
        print(result['stdout'])
    else:
        print(f"Ошибка: {result.get('stderr', 'Stats API не отвечает')}")
    
    return True

if __name__ == "__main__":
    main()
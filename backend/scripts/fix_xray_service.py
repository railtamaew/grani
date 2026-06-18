#!/usr/bin/env python3
"""
Диагностика и исправление проблем с Xray
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from sqlalchemy import text
from core.database import engine
from services.remote_vpn_manager import RemoteVPNManager
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

def main():
    """Основная функция"""
    print("\n" + "="*60)
    print("  ДИАГНОСТИКА И ИСПРАВЛЕНИЕ XRAY")
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
    
    # 1. Проверяем логи Xray
    print("1. Проверка логов Xray:")
    result = rm.ssh_manager.execute_command(
        ssh_config['host'],
        "journalctl -u xray-v2 -n 20 --no-pager",
        ssh_config['port'],
        ssh_config['username'],
        ssh_config.get('key_path'),
        ssh_config.get('key_content'),
        ssh_config.get('password')
    )
    if result['success']:
        print(result['stdout'])
    else:
        print(f"Ошибка: {result['stderr']}")
    
    # 2. Проверяем конфигурацию
    print("\n2. Проверка конфигурации Xray:")
    config_path = server.xray_config_path or "/usr/local/etc/xray/config.json"
    result = rm.ssh_manager.execute_command(
        ssh_config['host'],
        f"xray -test -config={config_path} 2>&1 || echo 'Ошибка проверки'",
        ssh_config['port'],
        ssh_config['username'],
        ssh_config.get('key_path'),
        ssh_config.get('key_content'),
        ssh_config.get('password')
    )
    print(result['stdout'] if result['success'] else result['stderr'])
    
    # 3. Показываем статус
    print("\n3. Статус сервиса:")
    result = rm.ssh_manager.execute_command(
        ssh_config['host'],
        "systemctl status xray-v2 --no-pager | head -15",
        ssh_config['port'],
        ssh_config['username'],
        ssh_config.get('key_path'),
        ssh_config.get('key_content'),
        ssh_config.get('password')
    )
    print(result['stdout'] if result['success'] else result['stderr'])
    
    # 4. Предлагаем перезапуск
    print("\n" + "="*60)
    print("  РЕКОМЕНДАЦИИ")
    print("="*60)
    print("Если сервис в статусе 'failed', выполните на сервере:")
    print("  systemctl restart xray-v2")
    print("  systemctl status xray-v2")
    print("\nЕсли есть ошибки в конфигурации, проверьте:")
    print(f"  {config_path}")
    
    return True

if __name__ == "__main__":
    main()
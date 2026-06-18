#!/usr/bin/env python3
"""Проверка доступности сервера Венгрии и поддержки XRay протокола"""

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlalchemy.orm import Session
from sqlalchemy import text
from core.database import SessionLocal
from services.remote_vpn_manager import RemoteVPNManager
import json

def check_hungary_server():
    """Проверяет сервер Венгрии"""
    db: Session = SessionLocal()
    
    try:
        # Находим сервер Венгрии через прямой SQL запрос
        result = db.execute(text("""
            SELECT id, name, country, ip_address, is_active, supported_protocols,
                   ssh_host, ssh_port, ssh_user, ssh_key_path, ssh_key_content, ssh_password
            FROM servers
            WHERE ip_address = :ip
        """), {"ip": "45.12.132.94"})
        
        server_row = result.first()
        
        if not server_row:
            print("❌ Сервер Венгрии (45.12.132.94) не найден в базе данных")
            return False
        
        server_id = server_row[0]
        server_name = server_row[1]
        server_country = server_row[2]
        server_ip = server_row[3]
        server_active = server_row[4]
        server_protocols = server_row[5]
        server_ssh_host = server_row[6]
        server_ssh_port = server_row[7]
        server_ssh_user = server_row[8]
        server_ssh_key_path = server_row[9]
        server_ssh_key_content = server_row[10]
        server_ssh_password = server_row[11]
        
        print(f"✅ Сервер найден: ID={server_id}, Name={server_name}, Country={server_country}")
        print(f"   IP: {server_ip}")
        print(f"   Active: {server_active}")
        print(f"   Supported protocols: {server_protocols}")
        
        # Проверяем поддержку XRay
        if server_protocols:
            try:
                if isinstance(server_protocols, str):
                    protocols = json.loads(server_protocols)
                else:
                    protocols = server_protocols if isinstance(server_protocols, list) else []
            except:
                protocols = []
            
            xray_supported = any('xray' in str(p).lower() or p in ['vless', 'vmess', 'reality'] for p in protocols)
            print(f"   XRay support: {'✅' if xray_supported else '❌'}")
            
            if not xray_supported:
                print("\n⚠️  Сервер не поддерживает XRay протоколы!")
                print("   Добавляем поддержку xray_vless...")
                
                # Добавляем xray_vless в supported_protocols
                if 'xray_vless' not in protocols:
                    protocols.append('xray_vless')
                    protocols_json = json.dumps(protocols)
                    db.execute(text("""
                        UPDATE servers
                        SET supported_protocols = :protocols
                        WHERE id = :id
                    """), {"protocols": protocols_json, "id": server_id})
                    db.commit()
                    print("   ✅ xray_vless добавлен в supported_protocols")
        else:
            print("   ⚠️  supported_protocols не указан, добавляем xray_vless...")
            protocols_json = json.dumps(['xray_vless', 'wireguard'])
            db.execute(text("""
                UPDATE servers
                SET supported_protocols = :protocols
                WHERE id = :id
            """), {"protocols": protocols_json, "id": server_id})
            db.commit()
            print("   ✅ supported_protocols установлен: ['xray_vless', 'wireguard']")
        
        # Создаем объект сервера для RemoteVPNManager (минимальный)
        class ServerProxy:
            def __init__(
                self,
                id,
                ip_address,
                ssh_host=None,
                ssh_port=None,
                ssh_user=None,
                ssh_key_path=None,
                ssh_key_content=None,
                ssh_password=None,
            ):
                self.id = id
                self.ip_address = ip_address
                self.ssh_host = ssh_host
                self.ssh_port = ssh_port
                self.ssh_user = ssh_user
                self.ssh_key_path = ssh_key_path
                self.ssh_key_content = ssh_key_content
                self.ssh_password = ssh_password
        
        server_proxy = ServerProxy(
            server_id,
            server_ip,
            ssh_host=server_ssh_host,
            ssh_port=server_ssh_port,
            ssh_user=server_ssh_user,
            ssh_key_path=server_ssh_key_path,
            ssh_key_content=server_ssh_key_content,
            ssh_password=server_ssh_password,
        )
        
        # Проверяем SSH подключение
        print("\n🔍 Проверка SSH подключения...")
        remote_manager = RemoteVPNManager()
        ssh_config = remote_manager.get_ssh_config(server_proxy)
        
        if ssh_config:
            print(f"   Host: {ssh_config['host']}")
            print(f"   Port: {ssh_config['port']}")
            print(f"   Username: {ssh_config['username']}")
            
            # Тестируем подключение
            test_result = remote_manager.ssh_manager.test_connection(
                ssh_config['host'],
                ssh_config['port'],
                ssh_config['username'],
                ssh_config.get('password'),
                ssh_config.get('key_path'),
                ssh_config.get('key_content')
            )
            
            if test_result:
                print("   ✅ SSH подключение успешно")
            else:
                print("   ❌ SSH подключение не удалось")
                return False
        else:
            print("   ❌ Не удалось получить SSH конфигурацию")
            return False
        
        # Проверяем XRay на сервере
        print("\n🔍 Проверка XRay на сервере...")
        try:
            # Проверяем, запущен ли XRay
            xray_check = remote_manager.ssh_manager.execute_command(
                ssh_config['host'],
                "systemctl is-active xray-v2",
                ssh_config['port'],
                ssh_config['username'],
                ssh_config.get('key_path'),
                ssh_config.get('key_content'),
                ssh_config.get('password')
            )
            
            if xray_check.get('success'):
                xray_status = xray_check.get('output', '').strip()
                print(f"   XRay status: {xray_status}")
                if xray_status == 'active':
                    print("   ✅ XRay запущен")
                else:
                    print("   ⚠️  XRay не запущен, пытаемся запустить...")
                    start_result = remote_manager.ssh_manager.execute_command(
                        ssh_config['host'],
                        "sudo systemctl start xray-v2",
                        ssh_config['port'],
                        ssh_config['username'],
                        ssh_config.get('key_path'),
                        ssh_config.get('key_content'),
                        ssh_config.get('password')
                    )
                    if start_result.get('success'):
                        print("   ✅ XRay запущен")
                    else:
                        print(f"   ❌ Не удалось запустить XRay: {start_result.get('error')}")
            else:
                print(f"   ❌ Не удалось проверить статус XRay: {xray_check.get('error')}")
        except Exception as e:
            print(f"   ⚠️  Ошибка проверки XRay: {e}")
        
        print("\n✅ Проверка завершена")
        return True
        
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False
    finally:
        db.close()

if __name__ == "__main__":
    check_hungary_server()


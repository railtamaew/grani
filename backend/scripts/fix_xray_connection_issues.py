#!/usr/bin/env python3
"""
Исправление проблем с XRay подключением
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from sqlalchemy import text
from core.database import SessionLocal
from services.remote_vpn_manager import RemoteVPNManager
from services.ssh_manager import SSHManager
import json

def print_status(message: str, status: str = "INFO"):
    color_map = {
        "INFO": "\033[0;34m",    # Blue
        "SUCCESS": "\033[0;32m", # Green
        "WARNING": "\033[1;33m", # Yellow
        "ERROR": "\033[0;31m",   # Red
        "NC": "\033[0m"          # No Color
    }
    print(f"{color_map.get(status, 'INFO')}[{status}]{color_map['NC']} {message}")

def fix_xray_connection(email: str, device_id: str):
    """Исправляет проблемы с XRay подключением"""
    db = SessionLocal()
    remote_manager = RemoteVPNManager()
    ssh_manager = SSHManager()
    
    try:
        print("\n" + "=" * 80)
        print("  ИСПРАВЛЕНИЕ ПРОБЛЕМ С XRAY ПОДКЛЮЧЕНИЕМ")
        print("=" * 80 + "\n")
        
        # 1. Получаем информацию о пользователе и устройстве
        user_result = db.execute(text("SELECT id FROM users WHERE email = :email"), {"email": email})
        user_row = user_result.fetchone()
        if not user_row:
            print_status(f"Пользователь {email} не найден", "ERROR")
            return
        user_id = user_row[0]
        
        device_result = db.execute(text("""
            SELECT id, device_id, current_server_id
            FROM devices 
            WHERE user_id = :user_id AND device_id = :device_id
        """), {"user_id": user_id, "device_id": device_id})
        device_row = device_result.fetchone()
        
        if not device_row:
            print_status("Устройство не найдено", "ERROR")
            return
        
        device_db_id = device_row[0]
        current_server_id = device_row[2]
        
        if not current_server_id:
            print_status("Устройство не подключено к серверу", "ERROR")
            return
        
        # 2. Получаем информацию о сервере
        server_result = db.execute(text("""
            SELECT id, name, ip_address, xray_port, ssh_host, ssh_port, ssh_user, ssh_password
            FROM servers 
            WHERE id = :server_id
        """), {"server_id": current_server_id})
        server_row = server_result.fetchone()
        
        server_id = server_row[0]
        server_ip = server_row[2]
        xray_port = server_row[3] or 4443
        ssh_host = server_row[4] or server_ip
        ssh_port = int(server_row[5]) if server_row[5] else 22
        ssh_user = server_row[6] or "root"
        ssh_password = server_row[7]
        
        print_status(f"Сервер: {server_row[1]} ({server_ip})", "SUCCESS")
        print(f"   XRay порт: {xray_port}")
        
        # 3. Проверяем, какой путь к конфигурации используется
        print("\n3. Проверка пути к конфигурации XRay...")
        config_paths = [
            "/usr/local/etc/xray/config.json",
            "/etc/xray/config.json"
        ]
        
        actual_config_path = None
        for path in config_paths:
            content = ssh_manager.download_content(
                ssh_host, path, ssh_port, ssh_user, None, None, ssh_password
            )
            if content:
                actual_config_path = path
                print_status(f"   ✅ Конфигурация найдена: {path}", "SUCCESS")
                break
        
        if not actual_config_path:
            print_status("Конфигурация XRay не найдена", "ERROR")
            return
        
        # 4. Читаем конфигурацию
        print("\n4. Чтение конфигурации XRay...")
        config_content = ssh_manager.download_content(
            ssh_host, actual_config_path, ssh_port, ssh_user, None, None, ssh_password
        )
        config = json.loads(config_content)
        
        # 5. Находим VLESS inbound и проверяем клиента
        print("\n5. Проверка клиента в конфигурации...")
        vless_inbound = None
        for inbound in config.get('inbounds', []):
            if inbound.get('protocol') == 'vless':
                vless_inbound = inbound
                break
        
        if not vless_inbound:
            print_status("VLESS inbound не найден", "ERROR")
            return
        
        device_email = f"{user_id}_{device_db_id}@granivpn.com"
        clients = vless_inbound.get('settings', {}).get('clients', [])
        
        # Проверяем, есть ли клиент
        client_exists = any(client.get('email') == device_email for client in clients)
        
        if not client_exists:
            print_status(f"Клиент для устройства не найден. Создаем...", "WARNING")
            
            # Создаем клиента вручную
            import uuid
            client_uuid = str(uuid.uuid4())
            clients.append({
                'id': client_uuid,
                'level': 0,
                'email': device_email
            })
            vless_inbound['settings']['clients'] = clients
            
            # Сохраняем конфигурацию
            config_json = json.dumps(config, indent=2)
            success = ssh_manager.upload_content(
                ssh_host, config_json, actual_config_path,
                ssh_port, ssh_user, None, None, ssh_password
            )
            if success:
                print_status(f"✅ Клиент добавлен: {client_uuid}", "SUCCESS")
                print(f"   Email: {device_email}")
            else:
                print_status("❌ Не удалось сохранить конфигурацию", "ERROR")
                return
        else:
            print_status("✅ Клиент уже существует в конфигурации", "SUCCESS")
        
        # 6. Проверяем порт
        print(f"\n6. Проверка порта {xray_port}...")
        port_check = ssh_manager.execute_command(
            ssh_host, f"netstat -tuln | grep :{xray_port}",
            ssh_port, ssh_user, None, None, ssh_password
        )
        
        if not (port_check['success'] and port_check['stdout'].strip()):
            print_status(f"Порт {xray_port} не слушается. Проверяем конфигурацию...", "WARNING")
            
            # Проверяем, какой порт указан в конфигурации
            config_port = vless_inbound.get('port')
            if config_port != xray_port:
                print_status(f"Порт в конфигурации ({config_port}) не совпадает с БД ({xray_port})", "WARNING")
                print_status(f"Обновляем порт в конфигурации на {xray_port}...", "INFO")
                vless_inbound['port'] = xray_port
                
                # Сохраняем конфигурацию
                config_json = json.dumps(config, indent=2)
                success = ssh_manager.upload_content(
                    ssh_host, config_json, actual_config_path,
                    ssh_port, ssh_user, None, None, ssh_password
                )
                if success:
                    print_status("✅ Порт обновлен в конфигурации", "SUCCESS")
                else:
                    print_status("❌ Не удалось обновить конфигурацию", "ERROR")
        
        # 7. Перезапускаем XRay
        print("\n7. Перезапуск XRay...")
        restart_result = ssh_manager.execute_command(
            ssh_host, "systemctl restart xray-v2",
            ssh_port, ssh_user, None, None, ssh_password
        )
        
        if restart_result['success']:
            print_status("✅ XRay перезапущен", "SUCCESS")
        else:
            print_status(f"❌ Ошибка перезапуска: {restart_result['stderr']}", "ERROR")
            return
        
        # 8. Проверяем порт после перезапуска
        import time
        time.sleep(2)
        
        print(f"\n8. Проверка порта {xray_port} после перезапуска...")
        port_check = ssh_manager.execute_command(
            ssh_host, f"netstat -tuln | grep :{xray_port}",
            ssh_port, ssh_user, None, None, ssh_password
        )
        
        if port_check['success'] and port_check['stdout'].strip():
            print_status(f"✅ Порт {xray_port} слушается:", "SUCCESS")
            print(port_check['stdout'])
        else:
            print_status(f"❌ Порт {xray_port} все еще не слушается", "ERROR")
            print_status("Проверьте логи XRay для выяснения причины", "WARNING")
        
        # 9. Обновляем путь к конфигурации в БД, если нужно
        if actual_config_path != "/etc/xray/config.json":
            print(f"\n9. Обновление пути к конфигурации в БД...")
            db.execute(text("""
                UPDATE servers 
                SET xray_config_path = :path 
                WHERE id = :server_id
            """), {"path": actual_config_path, "server_id": server_id})
            db.commit()
            print_status(f"✅ Путь обновлен в БД: {actual_config_path}", "SUCCESS")
        
        print("\n" + "=" * 80)
        print("  ИСПРАВЛЕНИЕ ЗАВЕРШЕНО")
        print("=" * 80)
        print("\n💡 Теперь попробуйте:")
        print("   1. Отключитесь от VPN в мобильном приложении")
        print("   2. Подключитесь заново через XRay VLESS")
        print("   3. Проверьте, изменился ли IP адрес")
        print("\n" + "=" * 80 + "\n")
        
    except Exception as e:
        print_status(f"Ошибка: {e}", "ERROR")
        import traceback
        traceback.print_exc()
    finally:
        db.close()

if __name__ == "__main__":
    import argparse
    import os

    parser = argparse.ArgumentParser(description="Исправление проблем с XRay подключением")
    parser.add_argument("--email", type=str, default=os.getenv("TEST_EMAIL"), help="Email (или TEST_EMAIL)")
    parser.add_argument("--device-id", type=str, required=True, help="Device ID")
    args = parser.parse_args()
    if not args.email:
        print("Укажите --email или TEST_EMAIL")
        sys.exit(1)
    fix_xray_connection(args.email, args.device_id)


#!/usr/bin/env python3
"""
Диагностика проблем с подключением через XRay
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

def diagnose_xray_connection(email: str = None, device_id: str = None):
    """Диагностика проблем с XRay подключением"""
    db = SessionLocal()
    remote_manager = RemoteVPNManager()
    ssh_manager = SSHManager()
    
    try:
        print("\n" + "=" * 80)
        print("  ДИАГНОСТИКА ПОДКЛЮЧЕНИЯ XRAY")
        print("=" * 80 + "\n")
        
        # 1. Получаем информацию о пользователе и устройстве
        print("1. Проверка устройства в БД...")
        if email:
            user_result = db.execute(text("SELECT id, email FROM users WHERE email = :email"), {"email": email})
            user_row = user_result.fetchone()
            if not user_row:
                print_status(f"Пользователь {email} не найден", "ERROR")
                return
            user_id = user_row[0]
        else:
            print_status("Укажите email или device_id", "ERROR")
            return
        
        device_result = db.execute(text("""
            SELECT id, device_id, device_name, is_active, current_server_id, 
                   ip_address, last_connected
            FROM devices 
            WHERE user_id = :user_id AND (device_id = :device_id OR :device_id IS NULL)
            ORDER BY last_connected DESC
            LIMIT 1
        """), {"user_id": user_id, "device_id": device_id})
        device_row = device_result.fetchone()
        
        if not device_row:
            print_status("Устройство не найдено", "ERROR")
            return
        
        device_db_id = device_row[0]
        device_id_found = device_row[1]
        device_name = device_row[2]
        is_active = device_row[3]
        current_server_id = device_row[4]
        ip_address = device_row[5]
        last_connected = device_row[6]
        
        print_status(f"Устройство найдено: {device_name or device_id_found}", "SUCCESS")
        print(f"   Device ID: {device_id_found}")
        print(f"   Статус в БД: {'Активно' if is_active else 'Неактивно'}")
        print(f"   Сервер ID: {current_server_id}")
        print(f"   IP в VPN: {ip_address}")
        print(f"   Последнее подключение: {last_connected}")
        
        # 2. Проверяем сервер
        if not current_server_id:
            print_status("Устройство не подключено к серверу", "WARNING")
            return
        
        print("\n2. Проверка сервера...")
        server_result = db.execute(text("""
            SELECT id, name, ip_address, xray_port, xray_config_path
            FROM servers 
            WHERE id = :server_id
        """), {"server_id": current_server_id})
        server_row = server_result.fetchone()
        
        if not server_row:
            print_status("Сервер не найден в БД", "ERROR")
            return
        
        server_id = server_row[0]
        server_name = server_row[1]
        server_ip = server_row[2]
        xray_port = server_row[3] or 4443
        # Проверяем оба возможных пути к конфигурации
        xray_config_path = server_row[4] or "/usr/local/etc/xray/config.json"
        
        # Проверяем, какой путь существует на сервере
        config_paths = [
            xray_config_path,
            "/usr/local/etc/xray/config.json",
            "/etc/xray/config.json"
        ]
        
        print_status(f"Сервер: {server_name} ({server_ip})", "SUCCESS")
        print(f"   XRay порт: {xray_port}")
        print(f"   Путь к конфигурации: {xray_config_path}")
        
        # 3. Проверяем SSH подключение
        print("\n3. Проверка SSH подключения...")
        ssh_result = db.execute(text("""
            SELECT ssh_host, ssh_port, ssh_user, ssh_password
            FROM servers 
            WHERE id = :server_id
        """), {"server_id": server_id})
        ssh_row = ssh_result.fetchone()
        
        if not ssh_row:
            print_status("SSH данные не найдены", "ERROR")
            return
        
        ssh_host = ssh_row[0] or server_ip
        ssh_port = int(ssh_row[1]) if ssh_row[1] else 22
        ssh_user = ssh_row[2] or "root"
        ssh_password = ssh_row[3]
        
        ssh_test = ssh_manager.test_connection(ssh_host, ssh_port, ssh_user, ssh_password, None, None)
        if ssh_test:
            print_status("SSH подключение работает", "SUCCESS")
        else:
            print_status("SSH подключение не работает", "ERROR")
            return
        
        # 4. Проверяем конфигурацию XRay на сервере
        print("\n4. Проверка конфигурации XRay на сервере...")
        
        # Пробуем найти правильный путь к конфигурации
        config_content = None
        actual_config_path = None
        
        for path in config_paths:
            print(f"   Проверяем путь: {path}")
            content = ssh_manager.download_content(
                ssh_host, path, ssh_port, ssh_user, None, None, ssh_password
            )
            if content:
                config_content = content
                actual_config_path = path
                print_status(f"   ✅ Конфигурация найдена: {path}", "SUCCESS")
                break
        
        if not config_content:
            print_status("Не удалось прочитать конфигурацию XRay ни по одному из путей", "ERROR")
            return
        
        try:
            config = json.loads(config_content)
            print_status("Конфигурация XRay прочитана", "SUCCESS")
            
            # Проверяем inbounds
            inbounds = config.get('inbounds', [])
            print(f"   Inbounds: {len(inbounds)}")
            
            vless_inbound = None
            for inbound in inbounds:
                if inbound.get('protocol') == 'vless':
                    vless_inbound = inbound
                    print(f"   ✅ VLESS inbound найден на порту {inbound.get('port')}")
                    clients = inbound.get('settings', {}).get('clients', [])
                    print(f"   Клиентов в конфигурации: {len(clients)}")
                    
                    # Проверяем, есть ли клиент для этого устройства
                    device_email = f"{user_id}_{device_db_id}@granivpn.com"
                    device_client = None
                    for client in clients:
                        if client.get('email') == device_email:
                            device_client = client
                            break
                    
                    if device_client:
                        print_status(f"   ✅ Клиент для устройства найден: {device_client.get('id')}", "SUCCESS")
                    else:
                        print_status(f"   ❌ Клиент для устройства НЕ найден", "ERROR")
                        print(f"      Искали email: {device_email}")
                        print(f"      Доступные клиенты:")
                        for client in clients:
                            print(f"         - {client.get('email')}: {client.get('id')}")
                    break
            
            if not vless_inbound:
                print_status("VLESS inbound не найден в конфигурации", "ERROR")
                return
                
        except json.JSONDecodeError as e:
            print_status(f"Ошибка парсинга JSON: {e}", "ERROR")
            return
        
        # 5. Проверяем статус XRay сервиса
        print("\n5. Проверка статуса XRay сервиса...")
        status_result = ssh_manager.execute_command(
            ssh_host, "systemctl status xray-v2 --no-pager | head -10",
            ssh_port, ssh_user, None, None, ssh_password
        )
        
        if status_result['success']:
            print_status("XRay сервис:", "SUCCESS")
            print(status_result['stdout'])
        else:
            print_status("Не удалось получить статус XRay", "WARNING")
            print(status_result['stderr'])
        
        # 6. Проверяем, слушается ли порт
        print(f"\n6. Проверка порта {xray_port}...")
        # Используем ss вместо netstat (netstat может быть не установлен)
        port_check = ssh_manager.execute_command(
            ssh_host, f"ss -tuln | grep :{xray_port} || lsof -i :{xray_port} 2>/dev/null || echo ''",
            ssh_port, ssh_user, None, None, ssh_password
        )
        
        if port_check['success'] and port_check['stdout'].strip():
            print_status(f"Порт {xray_port} слушается:", "SUCCESS")
            print(port_check['stdout'])
        else:
            print_status(f"Порт {xray_port} НЕ слушается", "ERROR")
        
        # 7. Проверяем логи XRay
        print("\n7. Последние логи XRay...")
        logs_result = ssh_manager.execute_command(
            ssh_host, "journalctl -u xray-v2 -n 20 --no-pager",
            ssh_port, ssh_user, None, None, ssh_password
        )
        
        if logs_result['success']:
            print("Последние 20 строк логов:")
            print(logs_result['stdout'])
        else:
            print_status("Не удалось получить логи", "WARNING")
        
        # 8. Проверяем последние подключения в БД
        print("\n8. Последние подключения устройства...")
        connections_result = db.execute(text("""
            SELECT connection_type, connected_at, server_id, ip_address
            FROM connection_logs
            WHERE device_id = :device_id
            ORDER BY connected_at DESC
            LIMIT 5
        """), {"device_id": device_db_id})
        connections = connections_result.fetchall()
        
        if connections:
            print("Последние 5 подключений:")
            for conn in connections:
                conn_type = "🔌 Подключение" if conn[0] == "connect" else "🔌❌ Отключение"
                print(f"   {conn_type}: {conn[1]} (Server {conn[2]}, IP: {conn[3]})")
        else:
            print_status("Нет записей о подключениях", "WARNING")
        
        # 9. Рекомендации
        print("\n" + "=" * 80)
        print("  РЕКОМЕНДАЦИИ")
        print("=" * 80)
        
        issues = []
        if not device_client:
            issues.append("Клиент XRay не создан на сервере")
        if not (port_check['success'] and port_check['stdout'].strip()):
            issues.append(f"Порт {xray_port} не слушается")
        if not is_active:
            issues.append("Устройство неактивно в БД")
        
        if issues:
            print_status("Обнаружены проблемы:", "ERROR")
            for issue in issues:
                print(f"   - {issue}")
            print("\n💡 Действия для исправления:")
            print("   1. Переподключитесь через мобильное приложение")
            print("   2. Проверьте логи бэкенда на ошибки")
            print("   3. Убедитесь, что XRay запущен на сервере")
            print("   4. Проверьте, что клиент создан в конфигурации XRay")
        else:
            print_status("Все проверки пройдены. Проблема может быть в клиентской конфигурации.", "WARNING")
            print("\n💡 Проверьте:")
            print("   1. Правильность конфигурации в мобильном приложении")
            print("   2. Настройки сети на устройстве")
            print("   3. Блокировку портов провайдером")
        
        print("\n" + "=" * 80 + "\n")
        
    except Exception as e:
        print_status(f"Ошибка: {e}", "ERROR")
        import traceback
        traceback.print_exc()
    finally:
        db.close()

if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description="Диагностика проблем с XRay подключением")
    parser.add_argument("--email", type=str, default=os.getenv("TEST_EMAIL"), help="Email (или TEST_EMAIL)")
    parser.add_argument("--device-id", type=str, help="Device ID (опционально)")
    
    args = parser.parse_args()
    diagnose_xray_connection(email=args.email, device_id=args.device_id)


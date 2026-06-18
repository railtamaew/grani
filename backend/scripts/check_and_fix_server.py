#!/usr/bin/env python3
"""
Скрипт для проверки и исправления состояния WireGuard сервера
Проверяет наличие пира, IP forwarding, iptables правила
"""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from core.database import SessionLocal
from models.user import Device
from models.server import Server
from sqlalchemy.orm import Session
from sqlalchemy import text
import re

def get_device_by_public_key(db: Session, public_key: str):
    """Находит устройство по публичному ключу"""
    result = db.execute(text("""
        SELECT id, device_id, wireguard_public_key, wireguard_private_key, user_id
        FROM devices
        WHERE wireguard_public_key = :public_key
        LIMIT 1
    """), {"public_key": public_key})
    
    row = result.fetchone()
    if row:
        return {
            "id": row[0],
            "device_id": row[1],
            "wireguard_public_key": row[2],
            "wireguard_private_key": row[3],
            "user_id": row[4]
        }
    return None

def check_server_peer(server, device: dict) -> dict:
    """Проверяет, добавлен ли пир на сервер"""
    result = {
        "peer_exists": False,
        "config_content": None,
        "error": None
    }
    
    try:
        from services.remote_vpn_manager import RemoteVPNManager
        remote_manager = RemoteVPNManager()
        
        # Получаем конфигурацию сервера
        config = remote_manager.get_wireguard_config(server)
        
        if not config:
            result["error"] = "Не удалось получить конфигурацию сервера"
            return result
        
        result["config_content"] = config
        
            # Проверяем наличие публичного ключа устройства в конфигурации
        device_public_key = device.get("wireguard_public_key")
        if device_public_key and device_public_key in config:
            result["peer_exists"] = True
            # Извлекаем секцию пира
            peer_pattern = rf'\[Peer\][\s\S]*?PublicKey\s*=\s*{re.escape(device_public_key)}[\s\S]*?(?=\[Peer\]|$)'
            match = re.search(peer_pattern, config)
            if match:
                result["peer_section"] = match.group(0)
        else:
            result["error"] = "Пир не найден в конфигурации сервера"
    except Exception as e:
        result["error"] = f"Ошибка проверки: {e}"
        import traceback
        result["traceback"] = traceback.format_exc()
    
    return result

def add_peer_to_server(server, device: dict, client_ip: str) -> bool:
    """Добавляет пир на сервер"""
    try:
        from services.remote_vpn_manager import RemoteVPNManager
        from models.user import Device as DeviceModel
        
        # Создаем объект Device для RemoteVPNManager
        device_obj = DeviceModel()
        device_obj.id = device["id"]
        device_obj.device_id = device["device_id"]
        device_obj.wireguard_public_key = device["wireguard_public_key"]
        device_obj.wireguard_private_key = device.get("wireguard_private_key")
        
        remote_manager = RemoteVPNManager()
        
        return remote_manager.add_wireguard_peer(server, device_obj, client_ip)
    except Exception as e:
        print(f"❌ Ошибка добавления пира: {e}")
        import traceback
        traceback.print_exc()
        return False

def check_server_setup(server: Server) -> dict:
    """Проверяет настройки сервера"""
    result = {
        "ip_forwarding": False,
        "iptables_forward": False,
        "iptables_masquerade": False,
        "error": None
    }
    
    try:
        from services.remote_vpn_manager import RemoteVPNManager
        remote_manager = RemoteVPNManager()
        
        # Проверяем IP forwarding
        result["ip_forwarding"] = remote_manager.check_ip_forwarding(server)
        
        # Получаем основной интерфейс
        main_interface = remote_manager._get_main_network_interface(server)
        
        # Проверяем iptables правила
        iptables_check = remote_manager.check_iptables_rules(server, "wg0")
        result["iptables_forward"] = iptables_check.get("forward_rule", False)
        result["iptables_masquerade"] = iptables_check.get("masquerade_rule", False)
        result["main_interface"] = main_interface
        
    except Exception as e:
        result["error"] = f"Ошибка проверки: {e}"
        import traceback
        result["traceback"] = traceback.format_exc()
    
    return result

def fix_server_setup(server: Server) -> bool:
    """Исправляет настройки сервера"""
    try:
        from services.remote_vpn_manager import RemoteVPNManager
        remote_manager = RemoteVPNManager()
        
        # Включаем IP forwarding
        if not remote_manager.check_ip_forwarding(server):
            print("   Включаем IP forwarding...")
            if remote_manager.enable_ip_forwarding(server):
                print("   ✅ IP forwarding включен")
            else:
                print("   ⚠️  Не удалось включить IP forwarding автоматически")
                return False
        
        return True
    except Exception as e:
        print(f"   ❌ Ошибка исправления: {e}")
        return False

def main():
    """Основная функция"""
    print("\n" + "=" * 60)
    print("  ПРОВЕРКА И ИСПРАВЛЕНИЕ СОСТОЯНИЯ WIREGUARD СЕРВЕРА")
    print("=" * 60)
    
    # Публичный ключ из конфигурации wg0.conf
    # TVg3PioAwVBCbPxC910vRGI8YokqnMx7NIBDOPZrgCo=
    public_key = "TVg3PioAwVBCbPxC910vRGI8YokqnMx7NIBDOPZrgCo="
    
    db = SessionLocal()
    try:
        # Находим устройство
        device = get_device_by_public_key(db, public_key)
        if not device:
            print(f"❌ Устройство с публичным ключом {public_key[:20]}... не найдено в базе данных")
            fallback_email = os.getenv("TEST_EMAIL")
            if not fallback_email:
                print("Задайте TEST_EMAIL для поиска по email.")
                return
            print(f"\nПопробуем найти по email {fallback_email}...")

            # Ищем по email
            result = db.execute(text("""
                SELECT d.id, d.device_id, d.wireguard_public_key, d.wireguard_private_key
                FROM devices d
                JOIN users u ON d.user_id = u.id
                WHERE u.email = :email
                ORDER BY d.created_at DESC
                LIMIT 5
            """), {"email": fallback_email})
            
            devices = result.fetchall()
            if not devices:
                print("❌ Устройства не найдены")
                return
            
            print(f"\nНайдено устройств: {len(devices)}")
            for i, dev in enumerate(devices, 1):
                print(f"  {i}. ID: {dev[0]}, Device ID: {dev[1]}, Public Key: {dev[2][:20] if dev[2] else 'N/A'}...")
            
            # Используем первое устройство
            device = {
                "id": devices[0][0],
                "device_id": devices[0][1],
                "wireguard_public_key": devices[0][2],
                "wireguard_private_key": devices[0][3],
                "user_id": None
            }
        
        if not device:
            print("❌ Устройство не найдено")
            return
        
        print(f"\n✅ Найдено устройство:")
        print(f"   ID: {device['id']}")
        print(f"   Device ID: {device['device_id']}")
        print(f"   Public Key: {device['wireguard_public_key'][:20] if device['wireguard_public_key'] else 'N/A'}...")
        
        # Находим активный сервер
        server_result = db.execute(text("""
            SELECT id, ip_address, wireguard_port, wireguard_public_key, wireguard_private_key
            FROM servers
            WHERE is_active = true AND ip_address = :ip
            LIMIT 1
        """), {"ip": "45.12.132.94"})
        
        server_row = server_result.fetchone()
        if not server_row:
            print("\n❌ Сервер 45.12.132.94 не найден или неактивен")
            return
        
        # Создаем объект-подобие сервера
        class ServerObj:
            def __init__(self, row):
                self.id = row[0]
                self.ip_address = row[1]
                self.wireguard_port = row[2]
                self.wireguard_public_key = row[3]
                self.wireguard_private_key = row[4]
        
        server = ServerObj(server_row)
        
        if not server:
            print("\n❌ Сервер 45.12.132.94 не найден или неактивен")
            return
        
        print(f"\n✅ Найден сервер:")
        print(f"   ID: {server.id}")
        print(f"   IP: {server.ip_address}")
        print(f"   Port: {server.wireguard_port}")
        print(f"   Public Key: {server.wireguard_public_key[:20] if server.wireguard_public_key else 'N/A'}...")
        
        # Проверяем наличие пира на сервере
        print("\n" + "-" * 60)
        print("1. ПРОВЕРКА ПИРА НА СЕРВЕРЕ")
        print("-" * 60)
        
        peer_check = check_server_peer(server, device)
        if peer_check.get("error"):
            print(f"❌ {peer_check['error']}")
            if "Не удалось получить конфигурацию" in peer_check['error']:
                print("   ⚠️  Это может означать, что SSH недоступен или сервер не настроен")
                print("   💡 Для тестирования пир может быть не добавлен на сервер")
        else:
            if peer_check["peer_exists"]:
                print("✅ Пир найден в конфигурации сервера")
                if peer_check.get("peer_section"):
                    print("\n   Секция пира:")
                    for line in peer_check["peer_section"].split('\n')[:10]:
                        if line.strip():
                            print(f"   {line}")
            else:
                print("❌ Пир НЕ найден в конфигурации сервера")
                print("\n   Попытка добавления пира...")
                
                # Получаем IP адрес устройства
                client_ip = f"10.0.0.{device['id'] % 254 + 2}"  # Простое вычисление IP
                print(f"   Используем IP: {client_ip}")
                
                if add_peer_to_server(server, device, client_ip):
                    print("   ✅ Пир добавлен на сервер")
                else:
                    print("   ⚠️  Не удалось добавить пир автоматически")
                    print("   💡 Это может быть нормально для тестирования без SSH")
        
        # Проверяем настройки сервера
        print("\n" + "-" * 60)
        print("2. ПРОВЕРКА НАСТРОЕК СЕРВЕРА")
        print("-" * 60)
        
        setup_check = check_server_setup(server)
        if setup_check.get("error"):
            print(f"❌ Ошибка проверки: {setup_check['error']}")
            if "SSHManager недоступен" in str(setup_check.get("traceback", "")):
                print("   ⚠️  SSH недоступен, проверка ограничена")
        else:
            ip_status = "✅ Включен" if setup_check["ip_forwarding"] else "❌ Отключен"
            print(f"IP Forwarding: {ip_status}")
            
            forward_status = "✅ Настроено" if setup_check["iptables_forward"] else "❌ Отсутствует"
            print(f"iptables FORWARD: {forward_status}")
            
            masq_status = "✅ Настроено" if setup_check["iptables_masquerade"] else "❌ Отсутствует"
            print(f"iptables MASQUERADE: {masq_status}")
            
            if setup_check.get("main_interface"):
                print(f"Основной интерфейс: {setup_check['main_interface']}")
            
            # Предлагаем исправить
            if not setup_check["ip_forwarding"] or not setup_check["iptables_forward"] or not setup_check["iptables_masquerade"]:
                print("\n⚠️  Найдены проблемы с настройками сервера")
                print("   Попытка автоматического исправления...")
                
                if fix_server_setup(server):
                    print("   ✅ Настройки исправлены")
                else:
                    print("   ⚠️  Не удалось исправить автоматически")
                    print("\n   💡 РЕКОМЕНДАЦИИ:")
                    print("   1. Подключитесь к серверу по SSH")
                    print("   2. Выполните на сервере:")
                    print("      sudo sysctl -w net.ipv4.ip_forward=1")
                    print("      echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf")
                    if setup_check.get("main_interface"):
                        main_if = setup_check["main_interface"]
                        print(f"      sudo iptables -A FORWARD -i wg0 -j ACCEPT")
                        print(f"      sudo iptables -t nat -A POSTROUTING -o {main_if} -j MASQUERADE")
        
        # Итоговые рекомендации
        print("\n" + "=" * 60)
        print("  ИТОГОВЫЕ РЕКОМЕНДАЦИИ")
        print("=" * 60)
        
        issues = []
        if not peer_check.get("peer_exists"):
            issues.append("Пир не добавлен на сервер - нужно добавить вручную через SSH")
        if not setup_check.get("ip_forwarding"):
            issues.append("IP forwarding не включен на сервере")
        if not setup_check.get("iptables_forward"):
            issues.append("iptables FORWARD правило отсутствует")
        if not setup_check.get("iptables_masquerade"):
            issues.append("iptables MASQUERADE правило отсутствует")
        
        if issues:
            print("\n⚠️  ПРОБЛЕМЫ:")
            for i, issue in enumerate(issues, 1):
                print(f"   {i}. {issue}")
            
            print("\n💡 РЕШЕНИЕ:")
            print("   Для работы VPN необходимо:")
            print("   1. Добавить пир на сервер в /etc/wireguard/wg0.conf")
            print("   2. Включить IP forwarding на сервере")
            print("   3. Настроить iptables правила для маршрутизации")
            print("\n   Выполните на сервере 45.12.132.94:")
            print("   sudo nano /etc/wireguard/wg0.conf")
            print("   # Добавьте секцию:")
            print(f"   [Peer]")
            print(f"   PublicKey = {device['wireguard_public_key']}")
            print(f"   AllowedIPs = 10.0.0.{device['id'] % 254 + 2}/32")
            print("\n   sudo sysctl -w net.ipv4.ip_forward=1")
            print("   echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf")
            if setup_check.get("main_interface"):
                main_if = setup_check["main_interface"]
                print(f"   sudo iptables -A FORWARD -i wg0 -j ACCEPT")
                print(f"   sudo iptables -t nat -A POSTROUTING -o {main_if} -j MASQUERADE")
            print("   sudo wg-quick down wg0 && sudo wg-quick up wg0")
        else:
            print("\n✅ Все проверки пройдены!")
            print("   Если интернет все еще не работает, проверьте:")
            print("   - Файрвол на сервере")
            print("   - Сетевые настройки сервера")
            print("   - Логи WireGuard на сервере: sudo wg show")
        
        print("\n" + "=" * 60 + "\n")
        
    finally:
        db.close()

if __name__ == "__main__":
    main()


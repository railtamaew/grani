#!/usr/bin/env python3
"""
Полная настройка сервера Венгрии (45.12.132.94)
Устанавливает и настраивает WireGuard + 3 протокола XRay (VLESS, VMESS, REALITY)
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from sqlalchemy import text
from core.database import SessionLocal
from models.server import Server
from services.xray_provisioning_service import XrayProvisioningService
from core.constants import XRAY_VLESS_DEFAULT_PORT, XRAY_REALITY_DEFAULT_PORT
import json

def setup_hungary_server():
    """Полная настройка сервера Венгрии"""
    db = SessionLocal()
    
    try:
        print("=" * 80)
        print("  НАСТРОЙКА СЕРВЕРА ВЕНГРИИ (45.12.132.94)")
        print("=" * 80)
        print()
        
        # 1. Находим сервер в БД
        print("1. Поиск сервера в базе данных...")
        result = db.execute(text("""
            SELECT id, name, country, ip_address, supported_protocols,
                   wireguard_port, xray_port, reality_enabled, reality_public_key
            FROM servers
            WHERE ip_address = :ip
        """), {"ip": "45.12.132.94"})
        
        server_row = result.first()
        if not server_row:
            print("❌ Сервер не найден в базе данных")
            print("   Создайте сервер через admin панель или скрипт create_server_direct.py")
            return False
        
        server_id = server_row[0]
        server_name = server_row[1]
        server_country = server_row[2]
        server_ip = server_row[3]
        supported_protocols = server_row[4]
        wg_port = server_row[5]
        reality_enabled = server_row[7]
        reality_public_key = server_row[8]
        
        print(f"   ✅ Сервер найден: ID={server_id}, Name={server_name}, Country={server_country}")
        print()
        
        # Загружаем полный объект сервера
        server = db.query(Server).filter(Server.id == server_id).first()
        if not server:
            print("❌ Не удалось загрузить объект сервера")
            return False
        
        # 2. Обновляем supported_protocols в БД
        print("2. Обновление протоколов в базе данных...")
        protocols = ['wireguard', 'xray_vless', 'xray_vmess', 'xray_reality']
        protocols_json = json.dumps(protocols)
        
        db.execute(text("""
            UPDATE servers
            SET supported_protocols = :protocols
            WHERE id = :id
        """), {"protocols": protocols_json, "id": server_id})
        db.commit()
        
        print(f"   ✅ Протоколы обновлены: {protocols}")
        print()
        
        # Обновляем объект сервера
        server = db.query(Server).filter(Server.id == server_id).first()
        
        # 3. Устанавливаем и настраиваем XRay
        print("3. Установка и настройка XRay...")
        provisioning_service = XrayProvisioningService()
        
        # Установка XRay
        install_result = provisioning_service.install_xray(server)
        if not install_result.get('success'):
            print(f"   ❌ Ошибка установки XRay: {install_result.get('error')}")
            return False
        
        print(f"   ✅ XRay установлен: {install_result.get('version', 'unknown')}")
        
        # Настройка базовой конфигурации (plain VLESS 4443, VMESS 8443; 443 под nginx API)
        config_result = provisioning_service.setup_base_xray_config(server, XRAY_VLESS_DEFAULT_PORT)
        if not config_result.get('success'):
            print(f"   ❌ Ошибка настройки конфигурации XRay: {config_result.get('error')}")
            return False
        
        print(f"   ✅ Базовая конфигурация XRay настроена (VLESS порт {XRAY_VLESS_DEFAULT_PORT})")
        
        # В БД xray_port = порт REALITY (не 443 — там reverse proxy к API)
        db.execute(text("""
            UPDATE servers
            SET xray_port = :port
            WHERE id = :id
        """), {"port": XRAY_REALITY_DEFAULT_PORT, "id": server_id})
        db.commit()
        server = db.query(Server).filter(Server.id == server_id).first()
        
        print()
        
        # 4. Настройка REALITY
        print("4. Настройка REALITY протокола...")
        reality_result = provisioning_service.setup_reality(server)
        
        if not reality_result.get('success'):
            print(f"   ⚠️  Ошибка настройки REALITY: {reality_result.get('error')}")
            print("   Продолжаем без REALITY...")
        else:
            # Обновляем REALITY ключи в БД
            db.execute(text("""
                UPDATE servers
                SET reality_enabled = true,
                    reality_public_key = :public_key,
                    reality_private_key = :private_key,
                    reality_short_id = :short_id,
                    reality_sni = :sni,
                    reality_dest = :dest
                WHERE id = :id
            """), {
                "public_key": reality_result['public_key'],
                "private_key": reality_result['private_key'],
                "short_id": reality_result['short_id'],
                "sni": reality_result['sni'],
                "dest": reality_result['dest'],
                "id": server_id
            })
            db.commit()
            
            print(f"   ✅ REALITY настроен:")
            print(f"      Public Key: {reality_result['public_key'][:40]}...")
            print(f"      Short ID: {reality_result['short_id']}")
            print(f"      SNI: {reality_result['sni']}")
            print(f"      Dest: {reality_result['dest']}")
        
        print()
        
        # 5. Запуск WireGuard (если не запущен)
        print("5. Проверка и запуск WireGuard...")
        from services.remote_vpn_manager import RemoteVPNManager
        remote_manager = RemoteVPNManager()
        wg_status = remote_manager.get_wireguard_status(server)
        
        if wg_status['status'] != 'running':
            print("   ⚠️  WireGuard не запущен, запускаем...")
            ssh_config = remote_manager.get_ssh_config(server)
            interface = getattr(server, 'wireguard_interface', 'wg0')
            
            # Запускаем WireGuard
            start_result = remote_manager.ssh_manager.execute_command(
                ssh_config['host'],
                f"systemctl start wg-quick@{interface} || wg-quick up {interface}",
                ssh_config['port'],
                ssh_config['username'],
                ssh_config.get('key_path'),
                ssh_config.get('key_content'),
                ssh_config.get('password')
            )
            
            if start_result['success']:
                print("   ✅ WireGuard запущен")
            else:
                print(f"   ⚠️  Не удалось запустить WireGuard: {start_result.get('stderr', 'unknown error')}")
        else:
            print(f"   ✅ WireGuard уже запущен")
        
        # 6. Проверка статуса сервисов
        print("\n6. Проверка статуса сервисов...")
        
        # Проверка WireGuard
        wg_status = remote_manager.get_wireguard_status(server)
        print(f"   {'✅' if wg_status['status'] == 'running' else '❌'} WireGuard: {wg_status['status']}")
        
        # Проверка XRay
        from services.xray_manager import XrayManager
        xray_manager = XrayManager(server)
        xray_health = xray_manager.check_server_health(server)
        print(f"   {'✅' if xray_health['status'] == 'healthy' else '❌'} XRay: {xray_health['status']}")
        
        print()
        
        # 6. Итоговая информация
        print("=" * 80)
        print("  НАСТРОЙКА ЗАВЕРШЕНА")
        print("=" * 80)
        print()
        print("✅ Сервер готов к работе с протоколами:")
        print("   1. WireGuard (порт 51820)")
        print("   2. XRay VLESS (порт 4443)")
        print("   3. XRay VMESS (порт 8443)")
        print(f"   4. XRay REALITY (порт {XRAY_REALITY_DEFAULT_PORT}, 443 — nginx API)")
        print()
        print("📱 Мобильное приложение может подключаться ко всем протоколам")
        print()
        
        return True
        
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        db.rollback()
        return False
    finally:
        db.close()

if __name__ == "__main__":
    success = setup_hungary_server()
    sys.exit(0 if success else 1)

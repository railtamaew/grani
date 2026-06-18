#!/usr/bin/env python3
"""
Скрипт для проверки статуса серверов и их протоколов
"""
import sys
import os

# Добавляем путь к backend
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from sqlalchemy.orm import Session
from core.database import SessionLocal, Base
from models.server import Server
# Импортируем все модели для правильной инициализации relationships
from models.user import User, Device
from models.subscription import Subscription

def check_servers():
    """Проверяет статус серверов и их протоколы"""
    db = SessionLocal()
    try:
        # Получаем все активные серверы
        active_servers = db.query(Server).filter(Server.is_active == True).all()
        all_servers = db.query(Server).all()
        
        print("=" * 80)
        print("📊 СТАТУС СЕРВЕРОВ И ПРОТОКОЛОВ")
        print("=" * 80)
        print(f"\nВсего серверов в БД: {len(all_servers)}")
        print(f"Активных серверов: {len(active_servers)}")
        print(f"Неактивных серверов: {len(all_servers) - len(active_servers)}")
        
        if not active_servers:
            print("\n⚠️  Нет активных серверов для тестирования!")
            return
        
        print("\n" + "=" * 80)
        print("📋 ДЕТАЛЬНАЯ ИНФОРМАЦИЯ ПО СЕРВЕРАМ")
        print("=" * 80)
        
        # Протоколы, поддерживаемые в мобильном приложении.
        # openvpn_cloak находится в архиве и намеренно не показывается.
        mobile_protocols = {
            'wireguard': 'WireGuard',
            'graniwg': 'GRANIWG',
            'xray_vless': 'XRay VLESS',
            'xray_vmess': 'XRay VMESS',
            'xray_reality': 'XRay Reality',
        }
        
        ready_count = 0
        not_ready_count = 0
        
        for server in active_servers:
            protocols = server.get_supported_protocols()
            
            # Проверяем, какие протоколы настроены
            protocol_status = {}
            for proto_key, proto_name in mobile_protocols.items():
                is_supported = proto_key in protocols
                is_enabled = False
                
                if proto_key == 'graniwg':
                    is_enabled = server.graniwg_enabled if hasattr(server, 'graniwg_enabled') else False
                elif proto_key == 'xray_reality':
                    is_enabled = server.reality_enabled if hasattr(server, 'reality_enabled') else False
                elif proto_key in ['wireguard', 'xray_vless', 'xray_vmess']:
                    is_enabled = is_supported  # Для базовых протоколов поддержка = включение
                
                protocol_status[proto_key] = {
                    'supported': is_supported,
                    'enabled': is_enabled,
                    'name': proto_name
                }
            
            # Сервер готов, если есть хотя бы один рабочий протокол
            has_working_protocol = any(
                status['supported'] and status['enabled'] 
                for status in protocol_status.values()
            )
            
            if has_working_protocol:
                ready_count += 1
            else:
                not_ready_count += 1
            
            # Выводим информацию о сервере
            print(f"\n🔹 Сервер #{server.id}: {server.name}")
            print(f"   Страна: {server.country}")
            print(f"   IP: {server.ip_address}")
            print(f"   Статус: {'✅ Активен' if server.is_active else '❌ Неактивен'}")
            print(f"   Пользователей: {server.current_users}/{server.max_users}")
            
            # Протоколы
            print(f"   Протоколы:")
            working_protocols = []
            for proto_key, status in protocol_status.items():
                if status['supported'] and status['enabled']:
                    print(f"      ✅ {status['name']} - Настроен и готов")
                    working_protocols.append(status['name'])
                elif status['supported'] and not status['enabled']:
                    print(f"      ⚠️  {status['name']} - В списке, но не включен")
                elif not status['supported']:
                    print(f"      ❌ {status['name']} - Не поддерживается")
            
            if not working_protocols:
                print(f"      ⚠️  Нет готовых протоколов для тестирования!")
            
            # Проверка совместимости
            print(f"   Совместимость с мобильным приложением:")
            compatible = True
            issues = []
            
            for proto_key, status in protocol_status.items():
                if status['supported'] and status['enabled']:
                    # Проверяем наличие необходимых полей
                    if proto_key == 'wireguard':
                        if not server.wireguard_public_key:
                            compatible = False
                            issues.append(f"WireGuard: отсутствует публичный ключ")
                    elif proto_key == 'graniwg':
                        if not server.graniwg_enabled:
                            compatible = False
                            issues.append(f"GRANIWG: не включен")
                        if not server.graniwg_obfuscation_key:
                            issues.append(f"GRANIWG: отсутствует ключ обфускации (не критично)")
                    elif proto_key == 'xray_reality':
                        if not server.reality_public_key or not server.reality_short_id:
                            compatible = False
                            issues.append(f"XRay Reality: отсутствуют ключи или short_id")
            
            if compatible and working_protocols:
                print(f"      ✅ Полностью совместим")
            elif working_protocols:
                print(f"      ⚠️  Частично совместим (есть проблемы):")
                for issue in issues:
                    print(f"         - {issue}")
            else:
                print(f"      ❌ Не совместим (нет рабочих протоколов)")
        
        print("\n" + "=" * 80)
        print("📈 СВОДКА")
        print("=" * 80)
        print(f"✅ Готовых для теста: {ready_count}")
        print(f"⚠️  Не готовых: {not_ready_count}")
        print(f"📊 Всего активных: {len(active_servers)}")
        
        # Статистика по протоколам
        print("\n📊 Статистика по протоколам:")
        protocol_stats = {}
        for server in active_servers:
            protocols = server.get_supported_protocols()
            for proto_key in mobile_protocols.keys():
                if proto_key not in protocol_stats:
                    protocol_stats[proto_key] = {'supported': 0, 'enabled': 0}
                
                if proto_key in protocols:
                    protocol_stats[proto_key]['supported'] += 1
                
                is_enabled = False
                if proto_key == 'graniwg':
                    is_enabled = server.graniwg_enabled if hasattr(server, 'graniwg_enabled') else False
                elif proto_key == 'xray_reality':
                    is_enabled = server.reality_enabled if hasattr(server, 'reality_enabled') else False
                elif proto_key in ['wireguard', 'xray_vless', 'xray_vmess']:
                    is_enabled = proto_key in protocols
                
                if is_enabled:
                    protocol_stats[proto_key]['enabled'] += 1
        
        for proto_key, stats in protocol_stats.items():
            proto_name = mobile_protocols[proto_key]
            print(f"   {proto_name}:")
            print(f"      Поддерживается на {stats['supported']} серверах")
            print(f"      Включен и готов на {stats['enabled']} серверах")
        
    finally:
        db.close()

if __name__ == "__main__":
    check_servers()


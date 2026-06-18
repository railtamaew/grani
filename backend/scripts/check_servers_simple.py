#!/usr/bin/env python3
"""
Простой скрипт для проверки статуса серверов через SQL
"""
import sys
import os
import json

# Добавляем путь к backend
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from sqlalchemy import text
from core.database import SessionLocal

def check_servers():
    """Проверяет статус серверов через SQL"""
    db = SessionLocal()
    try:
        conn = db.connection()
        # Получаем все серверы (проверяем наличие новых полей)
        # Сначала проверяем, какие поля существуют
        try:
            result = conn.execute(text("""
                SELECT column_name 
                FROM information_schema.columns 
                WHERE table_name = 'servers'
            """))
            columns = [row[0] for row in result.fetchall()]
            
            # Формируем запрос с учетом существующих полей
            base_fields = "id, name, country, ip_address, is_active, current_users, max_users, supported_protocols, wireguard_public_key"
            optional_fields = []
            
            if 'graniwg_enabled' in columns:
                optional_fields.append("graniwg_enabled, graniwg_obfuscation_key")
            if 'reality_enabled' in columns:
                optional_fields.append("reality_enabled, reality_public_key, reality_short_id")
            if 'cloak_enabled' in columns:
                optional_fields.append("cloak_enabled, cloak_uid, cloak_public_key")
            
            query_fields = base_fields
            if optional_fields:
                query_fields += ", " + ", ".join(optional_fields)
            
            result = conn.execute(text(f"""
                SELECT {query_fields}
                FROM servers
                ORDER BY id
            """))
        except Exception as e:
            # Fallback - используем только базовые поля
            result = conn.execute(text("""
                SELECT 
                    id, name, country, ip_address, is_active, 
                    current_users, max_users,
                    supported_protocols,
                    wireguard_public_key
                FROM servers
                ORDER BY id
            """))
            columns = []
        
        servers = result.fetchall()
        
        print("=" * 80)
        print("📊 СТАТУС СЕРВЕРОВ И ПРОТОКОЛОВ")
        print("=" * 80)
        
        active_servers = [s for s in servers if s.is_active]
        print(f"\nВсего серверов в БД: {len(servers)}")
        print(f"Активных серверов: {len(active_servers)}")
        print(f"Неактивных серверов: {len(servers) - len(active_servers)}")
        
        if not active_servers:
            print("\n⚠️  Нет активных серверов для тестирования!")
            return
        
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
        
        print("\n" + "=" * 80)
        print("📋 ДЕТАЛЬНАЯ ИНФОРМАЦИЯ ПО СЕРВЕРАМ")
        print("=" * 80)
        
        for server in active_servers:
            # Парсим supported_protocols
            protocols = []
            if server.supported_protocols:
                if isinstance(server.supported_protocols, str):
                    try:
                        protocols = json.loads(server.supported_protocols)
                    except:
                        protocols = [server.supported_protocols] if server.supported_protocols else []
                elif isinstance(server.supported_protocols, list):
                    protocols = server.supported_protocols
                else:
                    protocols = []
            
            if not protocols:
                protocols = ['wireguard']  # По умолчанию
            
            # Проверяем протоколы
            working_protocols = []
            protocol_details = []
            
            for proto_key, proto_name in mobile_protocols.items():
                is_supported = proto_key in protocols
                is_enabled = False
                is_configured = False
                
                if proto_key == 'wireguard':
                    is_enabled = is_supported
                    is_configured = bool(server.wireguard_public_key) if hasattr(server, 'wireguard_public_key') else False
                elif proto_key == 'graniwg':
                    is_enabled = bool(getattr(server, 'graniwg_enabled', False))
                    is_configured = bool(getattr(server, 'graniwg_obfuscation_key', None))
                elif proto_key == 'xray_reality':
                    is_enabled = bool(getattr(server, 'reality_enabled', False))
                    is_configured = bool(getattr(server, 'reality_public_key', None) and getattr(server, 'reality_short_id', None))
                elif proto_key in ['xray_vless', 'xray_vmess']:
                    is_enabled = is_supported
                    is_configured = is_supported  # Для базовых Xray протоколов поддержка = конфигурация
                
                if is_supported and is_enabled and is_configured:
                    working_protocols.append(proto_name)
                    protocol_details.append(f"✅ {proto_name}")
                elif is_supported and is_enabled:
                    protocol_details.append(f"⚠️  {proto_name} (не полностью настроен)")
                elif is_supported:
                    protocol_details.append(f"❌ {proto_name} (не включен)")
            
            # Сервер готов, если есть хотя бы один рабочий протокол
            has_working_protocol = len(working_protocols) > 0
            
            if has_working_protocol:
                ready_count += 1
            else:
                not_ready_count += 1
            
            # Выводим информацию
            status_icon = "✅" if has_working_protocol else "⚠️"
            print(f"\n{status_icon} Сервер #{server.id}: {server.name}")
            print(f"   Страна: {server.country}")
            print(f"   IP: {server.ip_address}")
            print(f"   Пользователей: {server.current_users}/{server.max_users}")
            print(f"   Протоколы: {', '.join(protocols) if protocols else 'не указаны'}")
            
            if protocol_details:
                print(f"   Статус протоколов:")
                for detail in protocol_details:
                    print(f"      {detail}")
            
            if working_protocols:
                print(f"   ✅ Готов для теста: {', '.join(working_protocols)}")
            else:
                print(f"   ⚠️  Нет готовых протоколов для тестирования")
        
        print("\n" + "=" * 80)
        print("📈 СВОДКА")
        print("=" * 80)
        print(f"✅ Готовых для теста: {ready_count}")
        print(f"⚠️  Не готовых: {not_ready_count}")
        print(f"📊 Всего активных: {len(active_servers)}")
        
        # Статистика по протоколам
        print("\n📊 Статистика по протоколам:")
        protocol_stats = {key: {'supported': 0, 'enabled': 0, 'configured': 0} 
                         for key in mobile_protocols.keys()}
        
        for server in active_servers:
            protocols = []
            if server.supported_protocols:
                if isinstance(server.supported_protocols, str):
                    try:
                        protocols = json.loads(server.supported_protocols)
                    except:
                        protocols = [server.supported_protocols] if server.supported_protocols else []
                elif isinstance(server.supported_protocols, list):
                    protocols = server.supported_protocols
            
            for proto_key in mobile_protocols.keys():
                if proto_key in protocols:
                    protocol_stats[proto_key]['supported'] += 1
                
                is_enabled = False
                is_configured = False
                
                if proto_key == 'wireguard':
                    is_enabled = proto_key in protocols
                    is_configured = bool(getattr(server, 'wireguard_public_key', None))
                elif proto_key == 'graniwg':
                    is_enabled = bool(getattr(server, 'graniwg_enabled', False))
                    is_configured = bool(getattr(server, 'graniwg_obfuscation_key', None))
                elif proto_key == 'xray_reality':
                    is_enabled = bool(getattr(server, 'reality_enabled', False))
                    is_configured = bool(getattr(server, 'reality_public_key', None) and getattr(server, 'reality_short_id', None))
                elif proto_key in ['xray_vless', 'xray_vmess']:
                    is_enabled = proto_key in protocols
                    is_configured = is_enabled
                
                if is_enabled:
                    protocol_stats[proto_key]['enabled'] += 1
                if is_configured:
                    protocol_stats[proto_key]['configured'] += 1
        
        for proto_key, stats in protocol_stats.items():
            proto_name = mobile_protocols[proto_key]
            print(f"   {proto_name}:")
            print(f"      Поддерживается: {stats['supported']} серверов")
            print(f"      Включен: {stats['enabled']} серверов")
            print(f"      Настроен и готов: {stats['configured']} серверов")
        
        print("\n" + "=" * 80)
        print("💡 РЕКОМЕНДАЦИИ")
        print("=" * 80)
        
        if ready_count == 0:
            print("⚠️  Нет готовых серверов для тестирования!")
            print("   Используйте скрипт setup_server_protocols.py для настройки протоколов")
        elif ready_count < len(active_servers):
            print(f"✅ {ready_count} серверов готовы для теста")
            print(f"⚠️  {not_ready_count} серверов требуют настройки")
            print("   Используйте скрипт setup_server_protocols.py для настройки")
        else:
            print(f"✅ Все {ready_count} активных серверов готовы для тестирования!")
        
        print("\n💡 Совместимость протоколов:")
        print("   Протоколы WireGuard, GRANIWG, XRay VLESS/VMESS/Reality")
        print("   полностью совместимы с мобильным приложением после обновления.")
    finally:
        db.close()

if __name__ == "__main__":
    try:
        check_servers()
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()


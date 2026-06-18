#!/usr/bin/env python3
"""
Скрипт для проверки настроек Xray и тестирования протоколов
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from sqlalchemy import text
from core.database import engine
from services.remote_vpn_manager import RemoteVPNManager
from services.xray_manager import XrayManager
import json

# Простой класс для представления сервера
class ServerProxy:
    def __init__(self, data):
        for key, value in data.items():
            setattr(self, key, value)
    
    def get_supported_protocols(self):
        if self.supported_protocols:
            if isinstance(self.supported_protocols, str):
                return json.loads(self.supported_protocols)
            return self.supported_protocols
        return ["wireguard"]

def check_server_settings():
    """Проверяет настройки сервера в базе данных"""
    print("\n" + "="*60)
    print("  ПРОВЕРКА НАСТРОЕК СЕРВЕРА")
    print("="*60 + "\n")
    
    try:
        with engine.connect() as conn:
            result = conn.execute(text("""
                SELECT id, name, ip_address, xray_port, xray_config_path, 
                       supported_protocols, ssh_host, ssh_port, ssh_user,
                       ssh_key_path, ssh_key_content IS NOT NULL as has_key_content,
                       ssh_password IS NOT NULL as has_password,
                       reality_enabled, reality_public_key IS NOT NULL as has_reality_key
                FROM servers 
                WHERE ip_address = :ip
                LIMIT 1
            """), {"ip": "45.12.132.94"})
            
            row = result.fetchone()
            
            if not row:
                print("❌ Сервер 45.12.132.94 не найден в базе данных")
                return None
            
            # Создаем объект сервера из результата
            server_data = {
                'id': row[0],
                'name': row[1],
                'ip_address': row[2],
                'xray_port': row[3],
                'xray_config_path': row[4],
                'supported_protocols': row[5],
                'ssh_host': row[6],
                'ssh_port': row[7],
                'ssh_user': row[8],
                'ssh_key_path': row[9],
                'ssh_key_content': None,  # Не загружаем содержимое для безопасности
                'ssh_password': None,  # Не загружаем пароль для безопасности
                'reality_enabled': row[12],
                'reality_public_key': None if not row[13] else 'SET',
                'reality_short_id': None,
                'reality_sni': None,
                'reality_dest': None,
                'is_local': False
            }
            
            server = ServerProxy(server_data)
            
            print(f"✅ Сервер найден: {server.name} (ID: {server.id})")
            print(f"   IP: {server.ip_address}")
            print(f"   Xray порт: {server.xray_port or 'НЕ УСТАНОВЛЕН'}")
            print(f"   Xray config path: {server.xray_config_path or 'НЕ УСТАНОВЛЕН'}")
            
            # Проверяем supported_protocols
            protocols = server.get_supported_protocols()
            xray_protocols = [p for p in protocols if 'xray' in p.lower()]
            print(f"   Поддерживаемые Xray протоколы: {', '.join(xray_protocols) if xray_protocols else 'НЕ НАСТРОЕНЫ'}")
            
            # Проверяем SSH настройки
            has_keys = bool(server.ssh_key_path or row[10])  # has_key_content
            has_password = bool(row[11])  # has_password
            print(f"   SSH ключи: {'✅ Настроены' if has_keys else '❌ Не настроены'}")
            print(f"   SSH пароль: {'✅ Настроен' if has_password else '❌ Не настроен'}")
            
            # Проверяем REALITY
            if server.reality_enabled:
                print(f"   REALITY: ✅ Включен")
                print(f"   REALITY ключи: {'✅ Настроены' if row[13] else '❌ Не настроены'}")
            else:
                print(f"   REALITY: ❌ Не включен")
            
            return server
            
    except Exception as e:
        print(f"❌ Ошибка при проверке настроек: {e}")
        import traceback
        traceback.print_exc()
        return None

def test_ssh_connection(server):
    """Тестирует SSH подключение к серверу"""
    print("\n" + "="*60)
    print("  ТЕСТ SSH ПОДКЛЮЧЕНИЯ")
    print("="*60 + "\n")
    
    rm = RemoteVPNManager()
    
    if not rm.ssh_manager:
        print("❌ SSHManager недоступен")
        return False
    
    try:
        ssh_config = rm.get_ssh_config(server)
        print(f"SSH конфигурация:")
        print(f"   Host: {ssh_config['host']}")
        print(f"   Port: {ssh_config['port']}")
        print(f"   Username: {ssh_config['username']}")
        print(f"   Key path: {ssh_config.get('key_path') or 'Не используется'}")
        print(f"   Key content: {'Установлен' if ssh_config.get('key_content') else 'Не используется'}")
        print(f"   Password: {'Установлен' if ssh_config.get('password') else 'Не используется'}")
        
        print("\nТестирование подключения...")
        test_result = rm.ssh_manager.test_connection(
            ssh_config['host'],
            ssh_config['port'],
            ssh_config['username'],
            ssh_config.get('password'),
            ssh_config.get('key_path'),
            ssh_config.get('key_content')
        )
        
        if test_result:
            print("✅ SSH подключение успешно!")
            return True
        else:
            print("❌ SSH подключение не удалось")
            return False
            
    except Exception as e:
        print(f"❌ Ошибка SSH подключения: {e}")
        return False

def test_xray_config_read(server):
    """Тестирует чтение конфигурации Xray"""
    print("\n" + "="*60)
    print("  ТЕСТ ЧТЕНИЯ КОНФИГУРАЦИИ XRAY")
    print("="*60 + "\n")
    
    xm = XrayManager()
    
    if not xm.remote_manager or not xm.remote_manager.ssh_manager:
        print("❌ XrayManager или SSHManager недоступен")
        return False
    
    try:
        config_path = xm._get_xray_config_path(server)
        print(f"Путь к конфигурации: {config_path}")
        
        print("Чтение конфигурации Xray...")
        config = xm._read_xray_config(server)
        
        if config:
            print("✅ Конфигурация Xray прочитана успешно!")
            print(f"   Inbounds: {len(config.get('inbounds', []))}")
            print(f"   Outbounds: {len(config.get('outbounds', []))}")
            
            # Показываем информацию о inbounds
            for inbound in config.get('inbounds', []):
                protocol = inbound.get('protocol', 'unknown')
                port = inbound.get('port', 'unknown')
                clients_count = len(inbound.get('settings', {}).get('clients', []))
                print(f"   - {protocol.upper()} на порту {port}: {clients_count} клиентов")
            
            return True
        else:
            print("⚠️  Конфигурация пуста или не найдена (будет создана при первом подключении)")
            return True  # Это нормально, конфигурация будет создана
            
    except Exception as e:
        error_msg = str(e)
        if "SSH недоступен" in error_msg:
            print(f"⚠️  {error_msg}")
            print("   Это нормально, если SSH еще не настроен")
        else:
            print(f"❌ Ошибка чтения конфигурации Xray: {e}")
            import traceback
            traceback.print_exc()
        return False

def main():
    """Основная функция"""
    print("\n" + "="*60)
    print("  ПРОВЕРКА И ТЕСТИРОВАНИЕ XRAY ПРОТОКОЛОВ")
    print("="*60)
    
    # 1. Проверка настроек сервера
    server = check_server_settings()
    if not server:
        print("\n❌ Не удалось найти сервер. Проверьте базу данных.")
        return False
    
    # 2. Тест SSH подключения
    ssh_ok = test_ssh_connection(server)
    if not ssh_ok:
        print("\n⚠️  SSH подключение не работает. Протоколы не смогут работать без SSH.")
        print("   Проверьте:")
        print("   - SSH ключи или пароль в базе данных")
        print("   - Доступность сервера 45.12.132.94")
        print("   - Настройки файрвола")
        return False
    
    # 3. Тест чтения конфигурации Xray
    config_ok = test_xray_config_read(server)
    if not config_ok:
        print("\n⚠️  Не удалось прочитать конфигурацию Xray.")
        print("   Это может быть нормально, если Xray еще не настроен.")
        print("   Конфигурация будет создана автоматически при первом подключении.")
    
    # Итоговый результат
    print("\n" + "="*60)
    print("  ИТОГОВЫЙ РЕЗУЛЬТАТ")
    print("="*60 + "\n")
    
    if ssh_ok:
        print("✅ SSH подключение работает")
        print("✅ Протоколы готовы к тестированию!")
        print("\nМожно протестировать создание клиента через API:")
        print("   POST /api/vpn/xray/create-client")
        print("   Body: {")
        print("     'server_id': 1,")
        print("     'device_id': 'your_device_id',")
        print("     'protocol': 'xray_vless'  // или xray_vmess, xray_reality")
        print("   }")
        return True
    else:
        print("❌ Протоколы не готовы - требуется настройка SSH")
        return False

if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)
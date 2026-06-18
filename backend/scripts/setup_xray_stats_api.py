#!/usr/bin/env python3
"""
Скрипт для проверки и настройки Xray Stats API
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

def get_server():
    """Получает сервер 45.12.132.94"""
    try:
        with engine.connect() as conn:
            result = conn.execute(text("""
                SELECT id, name, ip_address, xray_port, xray_config_path, 
                       supported_protocols, ssh_host, ssh_port, ssh_user,
                       ssh_key_path, ssh_key_content, ssh_password,
                       reality_enabled, reality_public_key, reality_private_key,
                       reality_short_id, reality_sni, reality_dest
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
                'supported_protocols': row[5], 'ssh_host': row[6],
                'ssh_port': row[7], 'ssh_user': row[8],
                'ssh_key_path': row[9], 'ssh_key_content': row[10],
                'ssh_password': row[11], 'reality_enabled': row[12],
                'reality_public_key': row[13], 'reality_private_key': row[14],
                'reality_short_id': row[15], 'reality_sni': row[16],
                'reality_dest': row[17], 'is_local': False
            }
            return ServerProxy(server_data)
    except Exception as e:
        print(f"❌ Ошибка получения сервера: {e}")
        return None

def check_stats_api(xm, server):
    """Проверяет наличие Stats API в конфигурации"""
    print("\n" + "="*60)
    print("  ПРОВЕРКА STATS API")
    print("="*60 + "\n")
    
    try:
        config = xm._read_xray_config(server)
        
        # Ищем DOKODEMO-DOOR на порту 10085
        stats_inbound = None
        for inbound in config.get('inbounds', []):
            if inbound.get('protocol') == 'dokodemo-door' and inbound.get('port') == 10085:
                stats_inbound = inbound
                break
        
        if stats_inbound:
            print("✅ Stats API найден в конфигурации (порт 10085)")
            print(f"   Настройки: {json.dumps(stats_inbound.get('settings', {}), indent=2)}")
            return True, config
        else:
            print("❌ Stats API не найден в конфигурации")
            print("   Нужно добавить DOKODEMO-DOOR inbound на порту 10085")
            return False, config
            
    except Exception as e:
        print(f"❌ Ошибка проверки конфигурации: {e}")
        return False, None

def add_stats_api(xm, server, config):
    """Добавляет Stats API в конфигурацию"""
    print("\n" + "="*60)
    print("  ДОБАВЛЕНИЕ STATS API")
    print("="*60 + "\n")
    
    try:
        # Проверяем, нет ли уже Stats API
        for inbound in config.get('inbounds', []):
            if inbound.get('protocol') == 'dokodemo-door' and inbound.get('port') == 10085:
                print("⚠️  Stats API уже существует, пропускаем")
                return True
        
        # Добавляем Stats API inbound
        stats_inbound = {
            "port": 10085,
            "protocol": "dokodemo-door",
            "settings": {
                "address": "127.0.0.1"
            },
            "tag": "api"
        }
        
        config.setdefault('inbounds', []).append(stats_inbound)
        
        # Записываем конфигурацию
        if xm._write_xray_config(server, config):
            print("✅ Stats API добавлен в конфигурацию")
            
            # Перезагружаем Xray
            if xm._reload_xray(server):
                print("✅ Xray перезагружен")
                return True
            else:
                print("⚠️  Stats API добавлен, но не удалось перезагрузить Xray")
                return False
        else:
            print("❌ Не удалось записать конфигурацию")
            return False
            
    except Exception as e:
        print(f"❌ Ошибка добавления Stats API: {e}")
        import traceback
        traceback.print_exc()
        return False

def test_stats_api(xm, server):
    """Тестирует доступность Stats API"""
    print("\n" + "="*60)
    print("  ТЕСТ STATS API")
    print("="*60 + "\n")
    
    try:
        # Пытаемся получить статистику через SSH
        ssh_config = xm._get_ssh_config(server)
        result = xm.remote_manager.ssh_manager.execute_command(
            ssh_config['host'],
            "curl -s 'http://127.0.0.1:10085/stats?reset=false' 2>&1",
            ssh_config['port'],
            ssh_config['username'],
            ssh_config.get('key_path'),
            ssh_config.get('key_content'),
            ssh_config.get('password')
        )
        
        if result['success']:
            output = result['stdout'].strip()
            if output:
                try:
                    stats_data = json.loads(output)
                    print("✅ Stats API доступен!")
                    print(f"   Ответ: {json.dumps(stats_data, indent=2)[:200]}...")
                    return True
                except json.JSONDecodeError:
                    print(f"⚠️  Stats API отвечает, но не JSON: {output[:100]}")
                    return False
            else:
                print("⚠️  Stats API не отвечает (пустой ответ)")
                print(f"   Stderr: {result['stderr']}")
                return False
        else:
            print(f"❌ Ошибка подключения к Stats API: {result['stderr']}")
            return False
            
    except Exception as e:
        print(f"❌ Ошибка тестирования Stats API: {e}")
        return False

def main():
    """Основная функция"""
    print("\n" + "="*60)
    print("  НАСТРОЙКА XRAY STATS API")
    print("="*60)
    
    server = get_server()
    if not server:
        print("❌ Сервер не найден")
        return False
    
    print(f"✅ Сервер: {server.name} ({server.ip_address})")
    
    xm = XrayManager()
    if not xm.remote_manager or not xm.remote_manager.ssh_manager:
        print("❌ SSH недоступен")
        return False
    
    # Шаг 1: Проверяем наличие Stats API
    has_stats, config = check_stats_api(xm, server)
    
    # Шаг 2: Если нет - добавляем
    if not has_stats:
        print("\n⚠️  Stats API не настроен. Добавляем...")
        if not add_stats_api(xm, server, config):
            print("❌ Не удалось добавить Stats API")
            return False
    else:
        print("\n✅ Stats API уже настроен")
    
    # Шаг 3: Тестируем доступность
    if test_stats_api(xm, server):
        print("\n✅ Stats API работает!")
        return True
    else:
        print("\n⚠️  Stats API может быть недоступен")
        print("   Проверьте:")
        print("   1. Xray запущен: systemctl status xray-v2")
        print("   2. Порт 10085 открыт: ss -tlnp | grep 10085")
        print("   3. Конфигурация корректна")
        return False

if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)
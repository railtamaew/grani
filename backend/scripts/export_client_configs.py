#!/usr/bin/env python3
"""
Экспорт конфигураций клиентов для тестирования на устройстве
"""
import sys
import os
import argparse
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import requests
import json
from datetime import datetime

def get_token(base_url: str, email: str, code: str):
    """Получает токен авторизации"""
    try:
        response = requests.post(
            f"{base_url}/api/auth/verify-code",
            json={"email": email, "code": code},
            timeout=10
        )
        if response.status_code == 200:
            return response.json().get('access_token')
        return None
    except Exception as e:
        print(f"Ошибка получения токена: {e}")
        return None

def get_client_configs(token, device_id):
    """Получает конфигурации всех протоколов"""
    protocols = ["xray_vless", "xray_vmess", "xray_reality"]
    configs = {}
    
    for protocol in protocols:
        try:
            response = requests.post(
                f"{BASE_URL}/api/vpn/xray/create-client",
                headers={"Authorization": f"Bearer {token}"},
                json={
                    "server_id": 1,
                    "device_id": device_id,
                    "protocol": protocol
                },
                timeout=30
            )
            
            if response.status_code == 200:
                data = response.json()
                configs[protocol] = {
                    "client_id": data.get('client_id'),
                    "config": data.get('config'),
                    "json_config": data.get('json_config'),
                    "server": data.get('server_name'),
                    "ip": data.get('ip_address')
                }
        except Exception as e:
            print(f"Ошибка получения конфигурации для {protocol}: {e}")
    
    return configs

def export_to_files(configs, output_dir="configs"):
    """Экспортирует конфигурации в файлы"""
    os.makedirs(output_dir, exist_ok=True)
    
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    
    # Экспортируем URL конфигурации
    urls_file = os.path.join(output_dir, f"configs_urls_{timestamp}.txt")
    with open(urls_file, 'w') as f:
        f.write("# Xray VPN Configurations\n")
        f.write(f"# Generated: {datetime.now().isoformat()}\n\n")
        for protocol, config in configs.items():
            f.write(f"# {protocol.upper()}\n")
            f.write(f"{config['config']}\n\n")
    
    # Экспортируем JSON конфигурации
    json_file = os.path.join(output_dir, f"configs_json_{timestamp}.json")
    with open(json_file, 'w') as f:
        json.dump(configs, f, indent=2, ensure_ascii=False)
    
    # Экспортируем отдельные файлы для каждого протокола
    for protocol, config in configs.items():
        protocol_name = protocol.replace('xray_', '')
        config_file = os.path.join(output_dir, f"{protocol_name}_{timestamp}.conf")
        with open(config_file, 'w') as f:
            f.write(f"# {protocol.upper()} Configuration\n")
            f.write(f"# Client ID: {config['client_id']}\n")
            f.write(f"# Server: {config['server']} ({config['ip']})\n\n")
            f.write(config['config'])
            f.write("\n")
    
    return {
        "urls_file": urls_file,
        "json_file": json_file,
        "config_files": [os.path.join(output_dir, f"{p.replace('xray_', '')}_{timestamp}.conf") 
                         for p in configs.keys()]
    }

def main():
    """Основная функция"""
    parser = argparse.ArgumentParser(description='Экспорт конфигураций Xray для тестирования')
    parser.add_argument('--code', type=str, required=True, help='Код авторизации из email')
    parser.add_argument('--device-id', type=str, default='test-device-api', help='ID устройства')
    parser.add_argument('--output', type=str, default='configs', help='Директория для экспорта')
    args = parser.parse_args()
    
    print("\n" + "="*60)
    print("  ЭКСПОРТ КОНФИГУРАЦИЙ XRAY")
    print("="*60 + "\n")
    
    # Получаем токен
    print("1. Получение токена...")
    token = get_token(args.code)
    if not token:
        print("❌ Не удалось получить токен")
        return False
    print("✅ Токен получен\n")
    
    # Получаем конфигурации
    print("2. Получение конфигураций...")
    configs = get_client_configs(token, args.device_id)
    if not configs:
        print("❌ Не удалось получить конфигурации")
        return False
    
    print(f"✅ Получено {len(configs)} конфигураций\n")
    
    # Экспортируем в файлы
    print("3. Экспорт в файлы...")
    files = export_to_files(configs, args.output)
    
    print("✅ Конфигурации экспортированы:")
    print(f"   URLs: {files['urls_file']}")
    print(f"   JSON: {files['json_file']}")
    for f in files['config_files']:
        print(f"   {f}")
    
    # Показываем конфигурации
    print("\n" + "="*60)
    print("  КОНФИГУРАЦИИ")
    print("="*60)
    for protocol, config in configs.items():
        print(f"\n{protocol.upper()}:")
        print(f"  Client ID: {config['client_id']}")
        print(f"  Config URL: {config['config'][:80]}...")
        print(f"  Server: {config['server']} ({config['ip']})")
    
    print("\n" + "="*60)
    print("  ИНСТРУКЦИЯ ДЛЯ ТЕСТИРОВАНИЯ")
    print("="*60)
    print("\n1. Скопируйте URL конфигурации из файла или выше")
    print("2. Откройте VPN клиент (v2rayNG, V2ray, или другой)")
    print("3. Импортируйте конфигурацию через QR-код или вставку URL")
    print("4. Подключитесь к VPN")
    print("5. Проверьте работу интернета и скорость\n")
    
    return True

if __name__ == "__main__":
    try:
        success = main()
        sys.exit(0 if success else 1)
    except KeyboardInterrupt:
        print("\n\n⚠️  Прервано пользователем")
        sys.exit(1)
    except Exception as e:
        print(f"\n❌ Критическая ошибка: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
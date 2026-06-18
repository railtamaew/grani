#!/usr/bin/env python3
"""
Тестирование всех Xray протоколов через API
"""
import sys
import os
import argparse
import time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import requests
import json

BASE_URL = os.getenv("API_URL", "https://api.granilink.com").rstrip("/")
EMAIL = os.getenv("TEST_EMAIL", "rail.tamaew@gmail.com")

EXPECTED_PORTS = {
    "xray_vless": 4443,
    "xray_vmess": 8443,
    "xray_reality": 2053,
}

def get_token(base_url: str, email: str, code=None):
    """Получает токен авторизации"""
    print("1. Получение токена...")
    print(f"   Email: {email}")
    
    if code:
        print(f"   Используется код из аргументов")
    else:
        print("   Введите код из email:")
        code = input("   Код: ").strip()
    
    try:
        response = requests.post(
            f"{base_url}/api/auth/verify-code",
            json={"email": email, "code": code},
            timeout=10
        )
        
        if response.status_code == 200:
            data = response.json()
            token = data.get('access_token') or data.get('token')
            if token:
                print(f"   ✅ Токен получен: {token[:20]}...")
                return token
            else:
                print(f"   ❌ Токен не найден в ответе: {data}")
                return None
        else:
            print(f"   ❌ Ошибка: {response.status_code}")
            try:
                print(f"   Ответ: {response.json()}")
            except:
                print(f"   Ответ: {response.text}")
            return None
    except Exception as e:
        print(f"   ❌ Исключение: {e}")
        return None

def register_device(token):
    """Регистрирует устройство"""
    print("\n2. Регистрация устройства...")
    
    device_id = f"test-device-api-{int(time.time())}"
    try:
        response = requests.post(
            f"{BASE_URL}/api/vpn/device/register",
            headers={"Authorization": f"Bearer {token}"},
            json={
                "device_id": device_id,
                "name": "Test Device API",
                "platform": "android"
            },
            timeout=10
        )
        
        if response.status_code == 200:
            data = response.json()
            print(f"   ✅ Устройство зарегистрировано: {device_id}")
            return device_id
        else:
            data = response.json() if response.status_code < 500 else {}
            if "уже зарегистрировано" in data.get('message', '').lower() or "already" in data.get('message', '').lower():
                print(f"   ⚠️  Устройство уже зарегистрировано: {device_id}")
                return device_id
            else:
                print(f"   ⚠️  Ответ: {data}")
                return device_id  # Пробуем продолжить
    except Exception as e:
        print(f"   ❌ Ошибка: {e}")
        return None

def test_protocol(token, device_id, protocol):
    """Тестирует создание клиента для протокола"""
    print(f"\n3. Тестирование протокола: {protocol}")
    
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
            print(f"   ✅ Клиент создан!")
            print(f"   Client ID: {data.get('client_id')}")
            config = data.get('config', '')
            if config:
                print(f"   Config: {config[:80]}...")
            print(f"   Server: {data.get('server_name')}")
            print(f"   IP: {data.get('ip_address')}")
            json_config = data.get('json_config') or {}
            if json_config:
                port = json_config.get('port')
                expected = EXPECTED_PORTS.get(protocol)
                if expected and str(port) != str(expected):
                    print(f"   ⚠️  Порт {port} не совпадает с ожидаемым {expected}")
                protocol_hint = json_config.get('protocol')
                if protocol_hint:
                    print(f"   JSON protocol: {protocol_hint}")
            return data
        else:
            error_data = response.json() if response.status_code < 500 else {}
            print(f"   ❌ Ошибка {response.status_code}: {error_data.get('detail', response.text)}")
            return None
    except Exception as e:
        print(f"   ❌ Исключение: {e}")
        return None

def get_stats(token, server_id=1):
    """Получает статистику сервера"""
    print(f"\n4. Получение статистики сервера {server_id}...")
    
    try:
        response = requests.get(
            f"{BASE_URL}/api/vpn/xray/stats?server_id={server_id}",
            headers={"Authorization": f"Bearer {token}"},
            timeout=10
        )
        
        if response.status_code == 200:
            stats = response.json()
            print(f"   ✅ Статистика получена:")
            print(f"   Uplink: {stats.get('total_uplink', 0)} bytes")
            print(f"   Downlink: {stats.get('total_downlink', 0)} bytes")
            print(f"   Активных клиентов: {stats.get('active_clients', 0)}")
            print(f"   Всего клиентов: {stats.get('total_clients', 0)}")
            if 'message' in stats:
                print(f"   ℹ️  {stats['message']}")
            return stats
        else:
            error_data = response.json() if response.status_code < 500 else {}
            print(f"   ❌ Ошибка {response.status_code}: {error_data.get('detail', response.text)}")
            return None
    except Exception as e:
        print(f"   ❌ Исключение: {e}")
        return None

def main():
    """Основная функция"""
    global EMAIL
    
    parser = argparse.ArgumentParser(description='Тестирование всех Xray протоколов')
    parser.add_argument('--code', type=str, help='Код авторизации из email')
    parser.add_argument('--email', type=str, default=EMAIL, help='Email для авторизации')
    parser.add_argument('--device-id', type=str, default=None, help='ID существующего устройства (пропускает регистрацию)')
    args = parser.parse_args()
    
    EMAIL = args.email
    
    print("\n" + "="*60)
    print("  ТЕСТИРОВАНИЕ ВСЕХ XRAY ПРОТОКОЛОВ")
    print("="*60)
    
    # 1. Получаем токен
    token = get_token(BASE_URL, EMAIL, args.code)
    if not token:
        print("\n❌ Не удалось получить токен")
        return False
    
    # 2. Регистрируем устройство
    if args.device_id:
        device_id = args.device_id
        print(f"\n2. Используем существующее устройство: {device_id}")
    else:
        device_id = register_device(token)
    if not device_id:
        print("\n❌ Не удалось зарегистрировать устройство")
        return False
    
    # 3. Тестируем протоколы
    protocols = ["xray_vless", "xray_vmess", "xray_reality"]
    results = {}
    
    for protocol in protocols:
        result = test_protocol(token, device_id, protocol)
        results[protocol] = result
    
    # 4. Получаем статистику
    get_stats(token)
    
    # Итоги
    print("\n" + "="*60)
    print("  ИТОГИ ТЕСТИРОВАНИЯ")
    print("="*60)
    for protocol, result in results.items():
        status = "✅" if result else "❌"
        print(f"{status} {protocol}: {'Успешно' if result else 'Ошибка'}")
    
    success_count = sum(1 for r in results.values() if r)
    print(f"\nУспешно: {success_count}/{len(protocols)}")
    
    return success_count > 0

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
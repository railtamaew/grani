#!/usr/bin/env python3
"""
Быстрый тест подключения через XRay
"""
import sys
import os
import argparse
import time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import requests
import json

def _get_token_via_code(email: str, code: str, base_url: str):
    try:
        response = requests.post(
            f"{base_url}/api/auth/verify-code",
            json={"email": email, "code": code},
            timeout=10
        )
        if response.status_code == 200:
            data = response.json()
            token = data.get("access_token")
            if token:
                print(f"✅ Токен получен: {token[:20]}...")
                return token
            print(f"❌ Токен не найден в ответе: {data}")
            return None
        print(f"❌ Ошибка токена: {response.status_code}")
        print(response.text)
        return None
    except Exception as e:
        print(f"❌ Ошибка получения токена: {e}")
        return None

EXPECTED_PORTS = {
    "xray_vless": 4443,
    "xray_vmess": 8443,
    "xray_reality": 2053,
}

def quick_test(email: str, api_base_url: str, protocol: str):
    """Быстрый тест XRay подключения"""
    base = api_base_url.rstrip("/")
    print(f"\n{'='*60}")
    print(f"  БЫСТРЫЙ ТЕСТ ПОДКЛЮЧЕНИЯ ЧЕРЕЗ XRAY")
    print(f"{'='*60}\n")

    # Получаем токен
    print("1. Получение токена...")
    token = _get_token_via_code(email, CODE, base)
    if not token:
        return False

    # Получаем список серверов
    print("2. Получение списка серверов...")
    try:
        response = requests.get(
            f"{base}/api/vpn/servers",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json"
            },
            timeout=10
        )
        
        if response.status_code == 200:
            servers = response.json()
            print(f"✅ Найдено серверов: {len(servers)}")
            for server in servers:
                protocols = server.get('supported_protocols', [])
                xray_protocols = [p for p in protocols if 'xray' in p.lower()]
                if xray_protocols:
                    print(f"   Сервер {server['id']}: {server['name']} ({server.get('ip_address', 'N/A')})")
                    print(f"      XRay протоколы: {', '.join(xray_protocols)}")
        else:
            print(f"❌ Ошибка получения серверов: {response.status_code}")
            print(response.text)
            return False
    except Exception as e:
        print(f"❌ Ошибка запроса: {e}")
        return False
    
    # Сначала отключаемся, если подключены
    print("\n3. Проверка текущего подключения...")
    device_id = f"cursor-vpn-tester-{os.getenv('USER', 'user')}"
    
    try:
        # Проверяем статус
        status_response = requests.get(
            f"{base}/api/vpn/status",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json"
            },
            params={"device_id": device_id},
            timeout=10
        )
        
        if status_response.status_code == 200:
            status = status_response.json()
            if status.get('connected'):
                print("   ⚠️  Устройство уже подключено. Отключаем...")
                disconnect_response = requests.post(
                    f"{base}/api/vpn/disconnect",
                    headers={
                        "Authorization": f"Bearer {token}",
                        "Content-Type": "application/json"
                    },
                    json={"device_id": device_id, "force": True},
                    timeout=10
                )
                if disconnect_response.status_code == 200:
                    print("   ✅ Отключено")
                else:
                    print(f"   ⚠️  Ошибка отключения: {disconnect_response.status_code}")
    except Exception as e:
        print(f"   ⚠️  Ошибка проверки статуса: {e}")
    
    # Создаем клиента через XRay
    print(f"\n4. Создание клиента через XRay ({protocol})...")
    
    try:
        response = requests.post(
            f"{base}/api/vpn/xray/create-client",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json"
            },
            json={
                "server_id": 1,
                "device_id": device_id,
                "protocol": protocol
            },
            timeout=30
        )
        
        if response.status_code == 200:
            result = response.json()
            print("✅ Клиент создан!")
            print(f"\n📋 Конфигурация:")
            print(json.dumps(result, indent=2, ensure_ascii=False))

            json_config = result.get("json_config") or {}
            if json_config:
                port = json_config.get("port")
                expected = EXPECTED_PORTS.get(protocol)
                if expected and str(port) != str(expected):
                    print(f"\n⚠️  Порт {port} не совпадает с ожидаемым {expected}")
            
            # Сохраняем конфигурацию в файл
            config_file = "/opt/grani/xray_config.json"
            with open(config_file, 'w') as f:
                json.dump(result, f, indent=2, ensure_ascii=False)
            print(f"\n💾 Конфигурация сохранена в: {config_file}")
            
            # Показываем, как использовать конфигурацию
            print(f"\n{'='*60}")
            print("  КАК ИСПОЛЬЗОВАТЬ КОНФИГУРАЦИЮ")
            print(f"{'='*60}\n")
            print("1. Для тестирования на компьютере:")
            print("   - Скачайте клиент XRay: https://github.com/XTLS/Xray-core/releases")
            print("   - Или используйте v2rayN (Windows): https://github.com/2dust/v2rayN")
            print("   - Импортируйте конфигурацию из файла xray_config.json")
            print("\n2. Для мобильного приложения:")
            print("   - Конфигурация будет использована автоматически")
            print("   - Выберите протокол 'XRay VLESS' в приложении")
            print(f"\n{'='*60}\n")
            
            return True
        else:
            print(f"❌ Ошибка подключения: {response.status_code}")
            print(response.text)
            return False
    except Exception as e:
        print(f"❌ Ошибка подключения: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Быстрый тест XRay подключения")
    parser.add_argument("--email", default=os.getenv("TEST_EMAIL", "rail.tamaew@gmail.com"), help="Email пользователя")
    parser.add_argument("--api-url", default=os.getenv("API_URL", "https://api.granilink.com"), help="URL API")
    parser.add_argument("--code", required=True, help="Код авторизации из email")
    parser.add_argument("--protocol", default="xray_vless", help="Протокол (xray_vless, xray_vmess, xray_reality)")
    args = parser.parse_args()

    EMAIL = args.email
    BASE_URL = args.api_url
    CODE = args.code

    success = quick_test(EMAIL, BASE_URL, args.protocol)
    sys.exit(0 if success else 1)


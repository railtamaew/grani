#!/usr/bin/env python3
"""Тестирование API endpoint /vpn/servers"""
import sys
import os
import requests
import json

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from core.database import SessionLocal
from models.user import User
from services.auth_service import AuthService

def test_servers_api():
    """Тестирует API endpoint для получения серверов"""
    # Получаем тестовый токен
    db = SessionLocal()
    try:
        # Находим первого активного пользователя
        user = db.query(User).filter(User.is_active == True).first()
        if not user:
            print("❌ Нет активных пользователей для тестирования")
            return False
        
        # Генерируем токен
        token = AuthService.create_access_token(user)
        print(f"✅ Токен создан для пользователя {user.id} ({user.email})")
        
        # Тестируем API
        base_url = os.getenv("API_URL", "https://api.granilink.com").rstrip("/")
        headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json"
        }
        
        print(f"\n📡 Тестирование GET {base_url}/api/vpn/servers")
        try:
            response = requests.get(
                f"{base_url}/api/vpn/servers",
                headers=headers,
                timeout=10
            )
            
            print(f"   Status Code: {response.status_code}")
            
            if response.status_code == 200:
                servers = response.json()
                print(f"   ✅ Получено серверов: {len(servers)}")
                
                if servers:
                    print(f"\n📋 Первый сервер:")
                    first = servers[0]
                    print(f"   ID: {first.get('id')}")
                    print(f"   Name: {first.get('name')}")
                    print(f"   Country: {first.get('country')}")
                    print(f"   IP: {first.get('ip_address')}")
                    print(f"   Is Active: {first.get('is_active')}")
                    print(f"   Supported Protocols: {first.get('supported_protocols')}")
                    print(f"   WireGuard Public Key: {'✅ есть' if first.get('wireguard_public_key') else '❌ отсутствует'}")
                    
                    print(f"\n📊 Все серверы:")
                    for server in servers:
                        protocols = server.get('supported_protocols', [])
                        wg_key = server.get('wireguard_public_key')
                        status = "✅" if server.get('is_active') else "❌"
                        wg_status = "✅" if wg_key else "⚠️"
                        print(f"   {status} {server.get('name')} ({server.get('country')}) - протоколы: {protocols}, WG ключ: {wg_status}")
                    
                    return True
                else:
                    print("   ⚠️  Список серверов пуст")
                    return False
            else:
                print(f"   ❌ Ошибка: {response.status_code}")
                print(f"   Ответ: {response.text}")
                return False
                
        except requests.exceptions.ConnectionError:
            print("   ❌ Не удалось подключиться к API. Убедитесь, что backend запущен.")
            return False
        except Exception as e:
            print(f"   ❌ Ошибка: {e}")
            import traceback
            traceback.print_exc()
            return False
            
    finally:
        db.close()

if __name__ == "__main__":
    print("=" * 80)
    print("🧪 ТЕСТИРОВАНИЕ API /vpn/servers")
    print("=" * 80)
    success = test_servers_api()
    sys.exit(0 if success else 1)



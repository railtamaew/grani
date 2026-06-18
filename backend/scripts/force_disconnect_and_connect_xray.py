#!/usr/bin/env python3
"""
Принудительное отключение и подключение через XRay
"""
import sys
import os
import argparse
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from core.database import SessionLocal
from services.auth_service import AuthService
from sqlalchemy import text
import requests
import json

def force_disconnect_and_connect(email: str, api_base_url: str, code: str = None):
    """Принудительно отключает и подключает через XRay"""
    base = api_base_url.rstrip("/")
    print(f"\n{'='*60}")
    print(f"  ПРИНУДИТЕЛЬНОЕ ОТКЛЮЧЕНИЕ И ПОДКЛЮЧЕНИЕ ЧЕРЕЗ XRAY")
    print(f"{'='*60}\n")

    # Получаем токен
    print("1. Получение токена...")
    token = None
    if code:
        try:
            response = requests.post(
                f"{base}/api/auth/verify-code",
                json={"email": email, "code": code},
                timeout=10
            )
            if response.status_code == 200:
                token = response.json().get("access_token")
            else:
                print(f"❌ Ошибка токена: {response.status_code}")
                print(response.text)
        except Exception as e:
            print(f"❌ Ошибка получения токена: {e}")

    if not token:
        print("❌ Не удалось получить токен по коду. Нужен новый код из email.")
        return False

    device_id = f"cursor-vpn-tester-{os.getenv('USER', 'user')}"
    
    # Принудительно отключаем через БД
    print("2. Принудительное отключение через БД...")
    db = SessionLocal()
    try:
        # Обнуляем last_connected и is_active для устройства
        result = db.execute(text("""
            UPDATE devices 
            SET last_connected = NULL, is_active = false
            WHERE device_id = :device_id AND user_id = :user_id
        """), {
            "device_id": device_id,
            "user_id": user_id
        })
        db.commit()
        if result.rowcount > 0:
            print(f"✅ Устройство отключено в БД (обновлено {result.rowcount} записей)\n")
        else:
            print(f"⚠️  Устройство не найдено в БД\n")
    except Exception as e:
        print(f"⚠️  Ошибка отключения в БД: {e}")
        db.rollback()
    finally:
        db.close()
    
    # Пробуем отключиться через API
    print("3. Отключение через API...")
    try:
        response = requests.post(
            f"{base}/api/vpn/disconnect",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json"
            },
            json={"device_id": device_id, "force": True},
            timeout=10
        )
        
        if response.status_code == 200:
            print("✅ Отключение через API выполнено")
        else:
            print(f"⚠️  Статус отключения: {response.status_code}")
            if response.status_code != 404:  # 404 - нормально, если не было подключения
                print(f"   Ответ: {response.text}")
    except Exception as e:
        print(f"⚠️  Ошибка отключения через API: {e}")
    
    # Подключаемся через XRay
    print("\n4. Подключение через XRay VLESS...")
    try:
        response = requests.post(
            f"{base}/api/vpn/connect",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json"
            },
            json={
                "server_id": 1,
                "device_id": device_id,
                "protocol": "xray_vless"
            },
            timeout=30
        )
        
        if response.status_code == 200:
            result = response.json()
            print("✅ Подключение установлено!")
            print(f"\n📋 Конфигурация XRay:")
            print(json.dumps(result, indent=2, ensure_ascii=False))
            
            # Сохраняем конфигурацию
            config_file = "/opt/grani/xray_config.json"
            with open(config_file, 'w') as f:
                json.dump(result, f, indent=2, ensure_ascii=False)
            print(f"\n💾 Конфигурация сохранена в: {config_file}")
            
            # Показываем URI для быстрого импорта
            if 'config' in result and isinstance(result['config'], str):
                if result['config'].startswith('vless://'):
                    print(f"\n🔗 URI для импорта:")
                    print(f"   {result['config']}")
            
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
    parser = argparse.ArgumentParser(description="Force disconnect and connect via XRay")
    parser.add_argument("--email", default=os.getenv("TEST_EMAIL", "rail.tamaew@gmail.com"), help="Email пользователя")
    parser.add_argument("--api-url", default=os.getenv("API_URL", "https://api.granilink.com"), help="URL API")
    parser.add_argument("--code", default=os.getenv("TEST_CODE"), help="Код авторизации из email")
    args = parser.parse_args()

    success = force_disconnect_and_connect(args.email, args.api_url, args.code)
    sys.exit(0 if success else 1)


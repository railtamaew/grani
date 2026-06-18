#!/usr/bin/env python3
"""Проверка пользователя и создание токена"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from sqlalchemy import text
from core.database import SessionLocal
from services.auth_service import AuthService

def check_user_and_token(email: str):
    """Проверяет пользователя и создает токен"""
    db = SessionLocal()
    try:
        conn = db.connection()
        
        # Проверяем пользователя
        result = conn.execute(text("""
            SELECT id, email, is_active, created_at, trial_active, trial_started_at
            FROM users
            WHERE email = :email
        """), {"email": email})
        
        user_row = result.fetchone()
        
        if not user_row:
            print(f"❌ Пользователь с email {email} не найден в базе данных")
            return None
        
        user_id, user_email, is_active, created_at, trial_active, trial_started_at = user_row
        
        print("=" * 80)
        print(f"👤 ИНФОРМАЦИЯ О ПОЛЬЗОВАТЕЛЕ")
        print("=" * 80)
        print(f"ID: {user_id}")
        print(f"Email: {user_email}")
        print(f"Активен: {'✅ Да' if is_active else '❌ Нет'}")
        print(f"Создан: {created_at}")
        print(f"Триал активен: {'✅ Да' if trial_active else '❌ Нет'}")
        if trial_started_at:
            print(f"Триал начат: {trial_started_at}")
        
        if not is_active:
            print("\n⚠️  Пользователь неактивен. Токен не может быть создан.")
            return None
        
        # Генерируем токен напрямую через user_id
        print("\n" + "=" * 80)
        print("🔑 ГЕНЕРАЦИЯ ТОКЕНА")
        print("=" * 80)
        
        try:
            token = AuthService.create_access_token(user_id)
            print(f"✅ Токен успешно создан!")
            print(f"\n📋 Токен (для использования в мобильном приложении):")
            print(f"{token}")
            print(f"\n💡 Использование:")
            print(f"   Скопируйте этот токен и используйте его в мобильном приложении")
            print(f"   или для тестирования API с заголовком:")
            print(f"   Authorization: Bearer {token[:50]}...")
            
            # Проверяем устройства пользователя
            devices_result = conn.execute(text("""
                SELECT id, device_id, device_name, is_active, created_at
                FROM devices
                WHERE user_id = :user_id
                ORDER BY created_at DESC
            """), {"user_id": user_id})
            
            devices = devices_result.fetchall()
            print(f"\n📱 Устройства пользователя: {len(devices)}")
            if devices:
                for device in devices:
                    dev_id, dev_device_id, dev_name, dev_active, dev_created = device
                    status = "✅ Активно" if dev_active else "❌ Неактивно"
                    print(f"   - {dev_name or dev_device_id} ({dev_device_id}) - {status}")
            else:
                print("   Нет зарегистрированных устройств")
            
            return token
            
        except Exception as e:
            print(f"❌ Ошибка создания токена: {e}")
            import traceback
            traceback.print_exc()
            return None
            
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return None
    finally:
        db.close()

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Проверка пользователя и токена")
    parser.add_argument("--email", default=os.getenv("TEST_EMAIL"), help="Email (или TEST_EMAIL)")
    args = parser.parse_args()
    if not args.email:
        print("Укажите --email или TEST_EMAIL")
        sys.exit(1)
    email = args.email
    print("=" * 80)
    print(f"🔍 ПРОВЕРКА ПОЛЬЗОВАТЕЛЯ И ТОКЕНА")
    print(f"Email: {email}")
    print("=" * 80)

    token = check_user_and_token(email)
    
    if token:
        print("\n✅ Готово! Токен создан и готов к использованию.")
    else:
        print("\n❌ Не удалось создать токен.")


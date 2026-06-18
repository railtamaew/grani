#!/usr/bin/env python3
"""Тестирование полного процесса регистрации с созданием токена"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from sqlalchemy import text
from core.database import SessionLocal
from services.auth_service import AuthService
from models.auth_code import AuthCode
from datetime import datetime, timedelta

def test_registration_flow(email: str):
    """Тестирует процесс регистрации"""
    db = SessionLocal()
    try:
        conn = db.connection()

        result = conn.execute(text("""
            SELECT id, email, is_active, is_verified, created_at
            FROM users
            WHERE email = :email
        """), {"email": email})
        
        user_row = result.fetchone()
        
        print("=" * 80)
        print("🧪 ТЕСТИРОВАНИЕ ПРОЦЕССА РЕГИСТРАЦИИ")
        print("=" * 80)
        
        if user_row:
            user_id, user_email, is_active, is_verified, created_at = user_row
            print(f"\n👤 Пользователь найден:")
            print(f"   ID: {user_id}")
            print(f"   Email: {user_email}")
            print(f"   Активен: {'✅' if is_active else '❌'}")
            print(f"   Верифицирован: {'✅' if is_verified else '❌'}")
            print(f"   Создан: {created_at}")
            
            # Проверяем, может ли быть создан токен
            if is_active:
                print(f"\n🔑 Тестирование создания токена...")
                try:
                    token = AuthService.create_access_token(user_id)
                    print(f"   ✅ Токен успешно создан!")
                    print(f"   Длина токена: {len(token)}")
                    print(f"   Токен (первые 50 символов): {token[:50]}...")
                    
                    # Проверяем валидность токена
                    verified_user_id = AuthService.verify_token(token)
                    if verified_user_id == user_id:
                        print(f"   ✅ Токен валиден, user_id: {verified_user_id}")
                    else:
                        print(f"   ❌ Токен невалиден или user_id не совпадает")
                    
                    return True
                except Exception as e:
                    print(f"   ❌ Ошибка создания токена: {e}")
                    return False
            else:
                print(f"\n⚠️  Пользователь неактивен, токен не может быть создан")
                return False
        else:
            print(f"\n❌ Пользователь {email} не найден")
            print(f"   При регистрации через /auth/send-code и /auth/verify-code")
            print(f"   пользователь будет создан автоматически и токен будет возвращен")
            return False
            
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False
    finally:
        db.close()

if __name__ == "__main__":
    success = test_registration_flow()
    print("\n" + "=" * 80)
    if success:
        print("✅ Процесс регистрации работает корректно")
        print("\n💡 При регистрации нового пользователя:")
        print("   1. /auth/send-code - отправляет код на email")
        print("   2. /auth/verify-code - проверяет код и возвращает токен")
        print("   3. Токен автоматически сохраняется в мобильном приложении")
    else:
        print("⚠️  Есть проблемы с процессом регистрации")
    print("=" * 80)



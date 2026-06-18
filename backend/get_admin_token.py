#!/usr/bin/env python3
"""
Скрипт для получения токена администратора
"""
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

from sqlalchemy import create_engine, text
from core.config import settings
from services.auth_service import AuthService
from datetime import datetime, timedelta
import jwt

def get_admin_token(email: str = None):
    """Получает токен для администратора"""
    if not email:
        email = os.getenv("TEST_EMAIL")
    if not email:
        print("Укажите email: аргумент или TEST_EMAIL")
        return None
    
    email_lower = email.lower().strip()
    
    print(f"\n{'='*60}")
    print(f"Получение токена для: {email_lower}")
    print(f"{'='*60}\n")
    
    engine = create_engine(settings.database_url)
    
    with engine.connect() as conn:
        # Проверяем пользователя через SQL
        user_query = text("""
            SELECT id, email, is_verified, is_active
            FROM users
            WHERE LOWER(email) = :email
            LIMIT 1
        """)
        user_result = conn.execute(user_query, {"email": email_lower}).fetchone()
        
        if not user_result:
            print(f"❌ Пользователь {email_lower} не найден")
            print(f"\nДля создания пользователя используйте:")
            print(f"  python3 init_db.py")
            return None
        
        user_id = user_result[0]
        print(f"✅ Пользователь найден:")
        print(f"   ID: {user_id}")
        print(f"   Email: {user_result[1]}")
        print(f"   Verified: {user_result[2]}")
        print(f"   Active: {user_result[3]}")
        
        # Создаем токен напрямую (как в AuthService)
        expire = datetime.utcnow() + timedelta(minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES)
        to_encode = {"exp": expire, "sub": str(user_id)}
        token = jwt.encode(to_encode, settings.SECRET_KEY, algorithm=settings.ALGORITHM)
        
        print(f"\n✅ Токен создан:")
        print(f"   Token: {token}")
        print(f"\n📋 Использование токена:")
        print(f"\n   1. В URL (для страницы /codes):")
        print(f"      https://api.granilink.com/codes?token={token}")
        print(f"\n   2. В заголовке HTTP (для API):")
        print(f"      Authorization: Bearer {token}")
        print(f"\n   3. В curl:")
        print(f"      curl -H 'Authorization: Bearer {token}' \\")
        print(f"           https://api.granilink.com/api/admin/auth-codes")
        print(f"\n   4. В curl с фильтром по email:")
        print(f"      curl -H 'Authorization: Bearer {token}' \\")
        print(f"           'https://api.granilink.com/api/admin/auth-codes?email={email_lower}'")
        print(f"\n   5. Сохранить в переменную (bash):")
        print(f"      export ADMIN_TOKEN='{token}'")
        print(f"      curl -H \"Authorization: Bearer $ADMIN_TOKEN\" \\")
        print(f"           https://api.granilink.com/api/admin/auth-codes")
        
        return token

if __name__ == "__main__":
    email = sys.argv[1] if len(sys.argv) > 1 else os.getenv("TEST_EMAIL")
    token = get_admin_token(email)
    sys.exit(0 if token else 1)


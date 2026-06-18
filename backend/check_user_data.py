#!/usr/bin/env python3
"""
Проверка данных пользователя через прямой SQL запрос
"""
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

from sqlalchemy import create_engine, text
from core.config import settings

def check_user_data(email: str = None):
    """Проверяет данные пользователя через SQL"""
    if not email:
        email = os.getenv("TEST_EMAIL")
    if not email:
        print("Укажите email или TEST_EMAIL")
        return
    engine = create_engine(settings.database_url)
    email_lower = email.lower()
    
    print('='*60)
    print(f'Проверка данных для: {email}')
    print('='*60)
    
    with engine.connect() as conn:
        # Проверяем пользователя
        user_query = text("""
            SELECT id, email, is_verified, is_active, auth_provider, created_at
            FROM users
            WHERE LOWER(email) = :email
            ORDER BY created_at DESC
            LIMIT 1
        """)
        user_result = conn.execute(user_query, {"email": email_lower}).fetchone()
        
        if user_result:
            print(f'\n✅ ПОЛЬЗОВАТЕЛЬ НАЙДЕН:')
            print(f'   ID: {user_result[0]}')
            print(f'   Email: {user_result[1]}')
            print(f'   Verified: {user_result[2]}')
            print(f'   Active: {user_result[3]}')
            print(f'   Auth Provider: {user_result[4]}')
            print(f'   Created: {user_result[5]}')
        else:
            print(f'\n❌ Пользователь не найден')
        
        # Проверяем коды
        print(f'\n📋 Последние коды авторизации:')
        codes_query = text("""
            SELECT id, email, code_hash, created_at, expires_at, attempts_count
            FROM auth_codes
            WHERE LOWER(email) = :email
            ORDER BY created_at DESC
            LIMIT 5
        """)
        codes_result = conn.execute(codes_query, {"email": email_lower}).fetchall()
        
        if codes_result:
            from datetime import datetime
            now = datetime.utcnow()
            for code in codes_result:
                expires_at = code[4]
                is_expired = expires_at < now if expires_at else True
                print(f'   ID: {code[0]}, Created: {code[3]}, Expires: {expires_at}, Expired: {is_expired}, Attempts: {code[5]}')
                print(f'   Hash (первые 16): {code[2][:16] if code[2] else "N/A"}...')
        else:
            print('   Коды не найдены')

if __name__ == "__main__":
    check_user_data()







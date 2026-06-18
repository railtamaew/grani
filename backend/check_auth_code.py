#!/usr/bin/env python3
"""
Скрипт для проверки кодов авторизации в базе данных
"""
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

from sqlalchemy.orm import Session
from sqlalchemy import func
from datetime import datetime
from core.database import SessionLocal
from models.auth_code import AuthCode
from services.code_service import hash_code, verify_code

def check_user_code(email: str, code: str = None):
    """Проверяет коды авторизации для пользователя"""
    db: Session = SessionLocal()
    try:
        email_lower = email.lower().strip()
        print(f"\n{'='*60}")
        print(f"Проверка кодов для: {email_lower}")
        print(f"{'='*60}\n")
        
        # Проверяем коды (включая истекшие)
        print(f"\n📋 Коды авторизации (все, включая истекшие):")
        auth_codes = db.query(AuthCode).filter(
            func.lower(AuthCode.email) == email_lower
        ).order_by(AuthCode.created_at.desc()).limit(10).all()
        
        if not auth_codes:
            print("   ❌ Коды не найдены в базе данных")
            print("   Возможные причины:")
            print("   - Код еще не был создан")
            print("   - Код был удален после использования")
            print("   - Email не совпадает (проверьте регистр)")
            return
        
        now = datetime.utcnow()
        print(f"   Найдено кодов: {len(auth_codes)}\n")
        
        for idx, auth_code in enumerate(auth_codes, 1):
            is_expired = auth_code.expires_at < now
            time_left = (auth_code.expires_at - now).total_seconds() if not is_expired else 0
            expired_ago = (now - auth_code.expires_at).total_seconds() if is_expired else 0
            
            print(f"   {'─'*50}")
            print(f"   Код #{idx}:")
            print(f"   ID: {auth_code.id}")
            print(f"   Email: {auth_code.email}")
            print(f"   Code Hash: {auth_code.code_hash}")
            print(f"   Hash (первые 16): {auth_code.code_hash[:16]}...")
            print(f"   Created: {auth_code.created_at}")
            print(f"   Expires: {auth_code.expires_at}")
            print(f"   Attempts: {auth_code.attempts_count}")
            print(f"   IP: {auth_code.ip_address}")
            if not is_expired:
                print(f"   Status: ✅ Активен")
                print(f"   Time left: {int(time_left)} секунд ({int(time_left/60)} минут)")
            else:
                print(f"   Status: ❌ Истек")
                print(f"   Истек: {int(expired_ago/60)} минут назад")
        
        # Если указан код для проверки
        if code:
            print(f"\n🔍 Проверка кода '{code}':")
            active_code = db.query(AuthCode).filter(
                func.lower(AuthCode.email) == email_lower,
                AuthCode.expires_at > now
            ).order_by(AuthCode.created_at.desc()).first()
            
            if not active_code:
                print("   ❌ Активный код не найден")
                return
            
            # Нормализуем код (как в code_service)
            import re
            normalized_code = re.sub(r'\s+', '', code.strip()) if code else ""
            code_hash_from_input = hash_code(normalized_code)
            
            print(f"   Введенный код: '{code}'")
            print(f"   Нормализованный: '{normalized_code}'")
            print(f"   Хеш введенного кода: {code_hash_from_input}")
            print(f"   Хеш в БД: {active_code.code_hash}")
            print(f"   Хеш введенного (первые 16): {code_hash_from_input[:16]}...")
            print(f"   Хеш в БД (первые 16): {active_code.code_hash[:16]}...")
            
            # Проверяем через verify_code
            result = verify_code(code, active_code.code_hash)
            if result:
                print(f"   ✅ КОД ВЕРНЫЙ! Хеши совпадают")
            else:
                print(f"   ❌ КОД НЕВЕРНЫЙ! Хеши не совпадают")
                print(f"   Разница в хешах: {code_hash_from_input != active_code.code_hash}")
        
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
    finally:
        db.close()

if __name__ == "__main__":
    email = os.getenv("TEST_EMAIL")
    code = sys.argv[2] if len(sys.argv) > 2 else os.getenv("TEST_CODE", "5922")
    if len(sys.argv) > 1:
        email = sys.argv[1]
    if not email:
        print("Укажите email: argv[1] или TEST_EMAIL")
        sys.exit(1)
    check_user_code(email, code)


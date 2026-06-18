#!/usr/bin/env python3
"""
Скрипт для исправления проблем подключения VPN для пользователя
Использование: python3 fix_user_connection.py 79172357737@ya.ru
"""

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from sqlalchemy.orm import Session
from sqlalchemy import text
from core.database import SessionLocal
from datetime import datetime, timedelta

def fix_user(email: str):
    db: Session = SessionLocal()
    try:
        print(f"\n{'='*60}")
        print(f"Исправление проблем для пользователя: {email}")
        print(f"{'='*60}\n")
        
        # 1. Находим пользователя через SQL
        user_result = db.execute(text("""
            SELECT id, email, trial_active, trial_seconds_left, trial_started_at
            FROM users 
            WHERE email = :email
        """), {"email": email}).fetchone()
        
        if not user_result:
            print("❌ ОШИБКА: Пользователь не найден в базе данных")
            return False
        
        user_id = user_result[0]
        user_email = user_result[1]
        trial_active = user_result[2]
        trial_seconds_left = user_result[3] or 0
        trial_started_at = user_result[4]
        
        print(f"✅ Пользователь найден: ID={user_id}, Email={user_email}\n")
        
        # 2. Проверяем и активируем триал
        print("📋 Проверка триала:")
        print(f"   Текущий статус: trial_active={trial_active}, trial_seconds_left={trial_seconds_left}")
        
        if not trial_active or trial_seconds_left <= 0:
            print("   ⚠️  Триал не активен или истек. Активируем триал...")
            trial_seconds = 600  # 10 минут = 600 секунд
            now = datetime.utcnow()
            
            db.execute(text("""
                UPDATE users 
                SET trial_active = true,
                    trial_seconds_left = :seconds,
                    trial_started_at = :started_at
                WHERE id = :user_id
            """), {
                "seconds": trial_seconds,
                "started_at": now,
                "user_id": user_id
            })
            db.commit()
            
            print(f"   ✅ Триал успешно активирован!")
            print(f"   trial_active: true")
            print(f"   trial_seconds_left: {trial_seconds} секунд ({trial_seconds // 60} минут)")
            print(f"   trial_started_at: {now}")
        else:
            print("   ✅ Триал уже активен")
        
        # 3. Проверяем финальный статус
        print(f"\n{'='*60}")
        print("ИТОГОВЫЙ СТАТУС:")
        print(f"{'='*60}\n")
        
        final_result = db.execute(text("""
            SELECT trial_active, trial_seconds_left, trial_started_at
            FROM users 
            WHERE id = :user_id
        """), {"user_id": user_id}).fetchone()
        
        print(f"✅ trial_active: {final_result[0]}")
        print(f"✅ trial_seconds_left: {final_result[1]} секунд ({final_result[1] // 60} минут)")
        print(f"✅ trial_started_at: {final_result[2]}")
        
        print(f"\n💡 Следующие шаги:")
        print(f"   1. Пользователь должен зарегистрировать устройство через /vpn/device/register")
        print(f"   2. После регистрации устройства можно подключаться к VPN")
        print(f"   3. Триал активен на {final_result[1] // 60} минут")
        
        return True
        
    except Exception as e:
        print(f"\n❌ ОШИБКА при исправлении: {e}")
        import traceback
        traceback.print_exc()
        db.rollback()
        return False
    finally:
        db.close()

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Использование: python3 fix_user_connection.py <email>")
        sys.exit(1)
    
    email = sys.argv[1]
    success = fix_user(email)
    sys.exit(0 if success else 1)


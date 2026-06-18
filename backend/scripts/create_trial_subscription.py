#!/usr/bin/env python3
"""Создает активную подписку/триал для пользователя"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from sqlalchemy import text
from core.database import SessionLocal
from datetime import datetime, timedelta

def create_trial_subscription(email: str, days: int = 30):
    """Создает триал подписку для пользователя"""
    db = SessionLocal()
    try:
        conn = db.connection()
        
        # Получаем пользователя
        user_result = conn.execute(text("""
            SELECT id FROM users WHERE email = :email AND is_active = true
        """), {"email": email.lower().strip()})
        
        user_row = user_result.fetchone()
        if not user_row:
            print(f"❌ Пользователь {email} не найден")
            return False
        
        user_id = user_row[0]
        print(f"✅ Пользователь найден: ID={user_id}")
        
        # Проверяем, есть ли уже активная подписка
        existing_sub = conn.execute(text("""
            SELECT id, status, end_date 
            FROM subscriptions 
            WHERE user_id = :user_id AND status = 'active'
            ORDER BY end_date DESC
            LIMIT 1
        """), {"user_id": user_id})
        
        existing = existing_sub.fetchone()
        if existing:
            sub_id, status, end_date = existing
            print(f"⚠️  У пользователя уже есть активная подписка (ID={sub_id})")
            print(f"   Статус: {status}, Действует до: {end_date}")
            
            # Продлеваем подписку
            new_end_date = datetime.utcnow() + timedelta(days=days)
            conn.execute(text("""
                UPDATE subscriptions 
                SET end_date = :end_date,
                    status = 'active'
                WHERE id = :sub_id
            """), {"sub_id": sub_id, "end_date": new_end_date})
            print(f"✅ Подписка продлена до {new_end_date}")
        else:
            # Создаем новую подписку с триал планом
            # Сначала находим или создаем триал план
            plan_result = conn.execute(text("""
                SELECT id FROM plans WHERE name LIKE '%trial%' OR name LIKE '%Trial%' LIMIT 1
            """))
            plan_row = plan_result.fetchone()
            
            if not plan_row:
                # Создаем триал план (PostgreSQL синтаксис)
                result = conn.execute(text("""
                    INSERT INTO plans (name, description, price, duration_days, max_speed_mbps, max_devices, is_active)
                    VALUES ('Trial', 'Trial Plan', 0, 30, 100, 999, true)
                    RETURNING id
                """))
                plan_id = result.fetchone()[0]
                print(f"✅ Создан триал план (ID={plan_id})")
            else:
                plan_id = plan_row[0]
                print(f"✅ Используется план (ID={plan_id})")
            
            # Создаем подписку
            start_date = datetime.utcnow()
            end_date = start_date + timedelta(days=days)
            
            conn.execute(text("""
                INSERT INTO subscriptions (user_id, plan_id, status, start_date, end_date, auto_renew)
                VALUES (:user_id, :plan_id, 'active', :start_date, :end_date, false)
            """), {
                "user_id": user_id,
                "plan_id": plan_id,
                "start_date": start_date,
                "end_date": end_date
            })
            print(f"✅ Создана активная подписка до {end_date}")
        
        db.commit()
        return True
        
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        db.rollback()
        return False
    finally:
        db.close()

if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description='Создание триал подписки')
    parser.add_argument('--email', default='rail.tamaew@gmail.com', help='Email пользователя')
    parser.add_argument('--days', type=int, default=30, help='Количество дней подписки')
    
    args = parser.parse_args()
    
    print("="*80)
    print(f"🎁 СОЗДАНИЕ ТРИАЛ ПОДПИСКИ")
    print(f"Email: {args.email}")
    print(f"Дней: {args.days}")
    print("="*80)
    print()
    
    create_trial_subscription(args.email, args.days)


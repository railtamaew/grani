#!/usr/bin/env python3
"""
Скрипт для диагностики проблем подключения VPN для пользователя
Использование: python3 check_user_connection.py 79172357737@ya.ru
"""

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from sqlalchemy.orm import Session
from core.database import SessionLocal
from models.user import User, Device
from models.server import Server
from models.subscription import Subscription
from models.payment import Payment  # Добавляем импорт Payment
from services.trial_service import is_trial_active, get_trial_seconds_left, has_active_subscription
from datetime import datetime

def _get_active_subscription(user: User, db: Session):
    """Получает активную подписку пользователя"""
    subscription = db.query(Subscription).filter(
        Subscription.user_id == user.id,
        Subscription.status == "active",
        Subscription.end_date > datetime.utcnow()
    ).first()
    return subscription

def check_user(email: str):
    db: Session = SessionLocal()
    try:
        print(f"\n{'='*60}")
        print(f"Проверка пользователя: {email}")
        print(f"{'='*60}\n")
        
        # 1. Проверка пользователя
        user = db.query(User).filter(User.email == email).first()
        if not user:
            print("❌ ОШИБКА: Пользователь не найден в базе данных")
            return
        
        print(f"✅ Пользователь найден:")
        print(f"   ID: {user.id}")
        print(f"   Email: {user.email}")
        print(f"   Активен: {user.is_active}")
        print(f"   Верифицирован: {user.is_verified}")
        print(f"   Создан: {user.created_at}")
        
        # 2. Проверка триала
        print(f"\n📋 Проверка триала:")
        print(f"   trial_active: {user.trial_active}")
        print(f"   trial_seconds_left: {user.trial_seconds_left}")
        print(f"   trial_started_at: {user.trial_started_at}")
        
        if user.trial_started_at:
            elapsed = (datetime.utcnow() - user.trial_started_at).total_seconds()
            print(f"   Прошло времени: {int(elapsed)} секунд ({int(elapsed/60)} минут)")
            remaining = max(0, user.trial_seconds_left - int(elapsed))
            print(f"   Осталось времени: {remaining} секунд ({int(remaining/60)} минут)")
        
        is_active = is_trial_active(user.id, db)
        print(f"   Триал активен (через сервис): {is_active}")
        
        if not user.trial_active and not has_active_subscription(user.id, db):
            print("   ⚠️  ПРОБЛЕМА: Триал не активен и нет подписки!")
        
        # 3. Проверка подписки
        print(f"\n💳 Проверка подписки:")
        subscription = _get_active_subscription(user, db)
        
        if subscription:
            print(f"   ✅ Активная подписка найдена")
            print(f"   План: {subscription.plan.name if subscription.plan else 'N/A'}")
            print(f"   До: {subscription.end_date}")
        else:
            print(f"   ❌ Активная подписка не найдена")
        
        has_sub = has_active_subscription(user.id, db)
        print(f"   has_active_subscription: {has_sub}")
        
        # 4. Проверка устройств
        print(f"\n📱 Проверка устройств:")
        # Используем прямой SQL запрос, чтобы избежать проблем с отсутствующими полями
        from sqlalchemy import text
        # Сначала проверим, какие поля есть в таблице
        try:
            devices_result = db.execute(text("""
                SELECT id, device_id, device_name, device_type, wireguard_public_key, 
                       is_active, last_connected, created_at
                FROM devices 
                WHERE user_id = :user_id
            """), {"user_id": user.id}).fetchall()
        except Exception as e:
            # Если есть ошибка, попробуем без некоторых полей
            print(f"   ⚠️  Предупреждение при запросе устройств: {e}")
            devices_result = db.execute(text("""
                SELECT id, device_id, device_name, device_type, wireguard_public_key, is_active, created_at
                FROM devices 
                WHERE user_id = :user_id
            """), {"user_id": user.id}).fetchall()
        
        if not devices_result:
            print("   ❌ ОШИБКА: У пользователя нет зарегистрированных устройств!")
            print("   💡 Решение: Пользователь должен зарегистрировать устройство через /vpn/device/register")
        else:
            for device_row in devices_result:
                print(f"\n   Устройство ID: {device_row[0]}")
                print(f"   device_id: {device_row[1]}")
                print(f"   name: {device_row[2]}")
                print(f"   platform: {device_row[3]}")
                wg_key = device_row[4] if len(device_row) > 4 else None
                print(f"   wireguard_public_key: {wg_key[:20] if wg_key else 'None'}...")
                is_active = device_row[5] if len(device_row) > 5 else False
                print(f"   is_active: {is_active}")
                if len(device_row) > 6:
                    print(f"   last_connected: {device_row[6]}")
                
                if is_active:
                    print("   ⚠️  Устройство уже подключено!")
                    print("   💡 Решение: Сначала отключите устройство")
        
        # 5. Проверка серверов
        print(f"\n🌐 Проверка серверов:")
        servers = db.query(Server).filter(Server.is_active == True).all()
        print(f"   Активных серверов: {len(servers)}")
        
        if not servers:
            print("   ❌ ОШИБКА: Нет активных серверов!")
        else:
            for server in servers[:5]:  # Показываем первые 5
                print(f"\n   Сервер ID: {server.id}")
                print(f"   name: {server.name}")
                print(f"   country: {server.country}")
                print(f"   ip_address: {server.ip_address}")
                print(f"   is_active: {server.is_active}")
                print(f"   supported_protocols: {server.supported_protocols}")
        
        # 6. Итоговая проверка доступа
        print(f"\n{'='*60}")
        print("ИТОГОВАЯ ПРОВЕРКА ДОСТУПА:")
        print(f"{'='*60}\n")
        
        subscription = _get_active_subscription(user, db)
        trial_active = getattr(user, 'trial_active', False)
        
        if subscription or trial_active:
            print("✅ Пользователь имеет доступ к VPN")
        else:
            print("❌ Пользователь НЕ имеет доступа к VPN")
            print("   Причина: Нет активной подписки и триал не активен")
            print("   💡 Решение: Активировать триал через trial_service.create_trial()")
        
        if devices_result:
            print("✅ У пользователя есть зарегистрированные устройства")
        else:
            print("❌ У пользователя нет зарегистрированных устройств")
        
        if servers:
            print("✅ Есть активные серверы")
        else:
            print("❌ Нет активных серверов")
        
        # 7. Проверка последних попыток подключения (если есть логи)
        print(f"\n📊 Последние устройства пользователя:")
        if devices_result:
            for device_row in devices_result:
                print(f"   - {device_row[2] or device_row[1]} (ID: {device_row[0]}, активен: {device_row[5]})")
        
    except Exception as e:
        print(f"\n❌ ОШИБКА при проверке: {e}")
        import traceback
        traceback.print_exc()
    finally:
        db.close()

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Использование: python3 check_user_connection.py <email>")
        sys.exit(1)
    
    email = sys.argv[1]
    check_user(email)


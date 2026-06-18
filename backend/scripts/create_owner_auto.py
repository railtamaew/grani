#!/usr/bin/env python3
"""Скрипт для автоматического создания Owner пользователя"""
import sys
import os

# Добавляем путь к backend
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Импортируем все модели для корректной инициализации relationships
import models.user
import models.subscription
import models.payment
import models.server
import models.auth_code
# Новые модели, связанные с User
import models.admin_login_log
import models.audit_log

from sqlalchemy.orm import Session
from core.database import SessionLocal
from models.user import User, UserRole
from services.auth_service import AuthService

def create_owner_auto(email: str, password: str):
    """Создает Owner пользователя с заданным паролем"""
    db: Session = SessionLocal()
    
    try:
        # Проверяем, существует ли пользователь
        existing_user = db.query(User).filter(User.email == email.lower()).first()
        
        if existing_user:
            # Обновляем существующего пользователя
            print(f"Пользователь {email} уже существует. Обновляем роль на Owner...")
            existing_user.role = UserRole.OWNER
            existing_user.is_active = True
            existing_user.is_verified = True
            existing_user.password_hash = AuthService.hash_password(password)
            
            db.commit()
            db.refresh(existing_user)
            print(f"✅ Пользователь {email} обновлен. Роль: {existing_user.role.value}")
            return existing_user
        else:
            # Создаем нового пользователя
            print(f"Создание нового Owner пользователя {email}...")
            owner = User(
                email=email.lower(),
                password_hash=AuthService.hash_password(password),
                role=UserRole.OWNER,
                is_active=True,
                is_verified=True
            )
            
            db.add(owner)
            db.commit()
            db.refresh(owner)
            print(f"✅ Owner пользователь {email} создан успешно!")
            print(f"   ID: {owner.id}")
            print(f"   Email: {owner.email}")
            print(f"   Role: {owner.role.value}")
            return owner
            
    except Exception as e:
        db.rollback()
        print(f"❌ Ошибка: {e}")
        raise
    finally:
        db.close()

if __name__ == "__main__":
    email = os.environ.get("OWNER_EMAIL")
    if not email:
        print("Задайте OWNER_EMAIL")
        sys.exit(1)
    password = os.environ.get("OWNER_PASSWORD")
    if not password:
        print("Задайте OWNER_PASSWORD")
        sys.exit(1)
    
    try:
        create_owner_auto(email, password)
        print(f"\n✅ Готово! Owner пользователь создан.")
        print(f"   Email: {email}")
        print(f"   Пароль: {password}")
        print(f"\n⚠️  ВАЖНО: Измените пароль после первого входа!")
    except Exception as e:
        print(f"\n❌ Не удалось создать пользователя: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


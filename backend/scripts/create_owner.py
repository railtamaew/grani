#!/usr/bin/env python3
"""Скрипт для создания Owner пользователя"""
import sys
import os

# Добавляем путь к backend
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlalchemy.orm import Session
from core.database import SessionLocal
from models.user import User, UserRole
from services.auth_service import AuthService
import getpass

def create_owner(email: str, password: str = None):
    """Создает Owner пользователя"""
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
            
            if password:
                existing_user.password_hash = AuthService.hash_password(password)
                print("Пароль обновлен.")
            
            db.commit()
            db.refresh(existing_user)
            print(f"✅ Пользователь {email} обновлен. Роль: {existing_user.role.value}")
            return existing_user
        else:
            # Создаем нового пользователя
            if not password:
                raise ValueError("Для нового пользователя необходимо указать пароль")
            
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
    import os
    email = os.getenv("OWNER_EMAIL")
    if not email:
        print("Задайте OWNER_EMAIL или передайте --email")
        if len(sys.argv) > 1:
            email = sys.argv[1]
        if not email:
            sys.exit(1)

    # Запрашиваем пароль
    print(f"Создание Owner пользователя: {email}")
    password = getpass.getpass("Введите пароль: ")
    password_confirm = getpass.getpass("Подтвердите пароль: ")
    
    if password != password_confirm:
        print("❌ Пароли не совпадают!")
        sys.exit(1)
    
    if len(password) < 8:
        print("⚠️  Внимание: пароль слишком короткий (минимум 8 символов)")
        response = input("Продолжить? (y/n): ")
        if response.lower() != 'y':
            sys.exit(0)
    
    try:
        create_owner(email, password)
        print("\n✅ Готово! Теперь вы можете войти в админ-панель.")
        print(f"   Email: {email}")
        print(f"   URL: http://localhost:3000 или https://granilink.com/admin")
    except Exception as e:
        print(f"\n❌ Не удалось создать пользователя: {e}")
        sys.exit(1)




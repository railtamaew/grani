#!/usr/bin/env python3
"""
Скрипт для инициализации базы данных и создания первого администратора
"""
import sys
from core.database import Base, engine, SessionLocal
from models.user import User
from models.auth_code import AuthCode  # Новая модель для кодов
from models.protocol_stats import ProtocolStats  # Модель для статистики протоколов
from services.auth_service import AuthService

def init_database():
    """Создание всех таблиц в базе данных"""
    print("Создание таблиц в базе данных...")
    Base.metadata.create_all(bind=engine)
    print("✓ Таблицы созданы")

def create_admin(email: str, password: str):
    """Создание администратора"""
    db = SessionLocal()
    try:
        auth_service = AuthService(db)
        
        # Проверяем, существует ли пользователь
        existing_user = db.query(User).filter(User.email == email).first()
        if existing_user:
            print(f"⚠ Пользователь {email} уже существует")
            return False
        
        # Создаем администратора
        user = auth_service.create_user(email, password)
        print(f"✓ Администратор создан: {email}")
        return True
    except Exception as e:
        print(f"✗ Ошибка создания администратора: {e}")
        return False
    finally:
        db.close()

if __name__ == "__main__":
    import os
    from core.config import settings

    print("=== Инициализация базы данных GraniVPN ===\n")

    # Инициализация базы данных
    init_database()
    print()

    # Создание администратора. В production ADMIN_PASSWORD обязателен через env.
    admin_email = os.getenv("ADMIN_EMAIL", "admin@granilink.com")
    admin_password = os.getenv("ADMIN_PASSWORD")
    if not admin_password:
        if settings.is_production:
            print("✗ Ошибка: в production задайте ADMIN_PASSWORD через переменную окружения.")
            sys.exit(1)
        admin_password = "admin123"  # только для development

    print(f"Создание администратора ({admin_email})...")
    create_admin(admin_email, admin_password)
    print()

    print("=== Инициализация завершена ===")


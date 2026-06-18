#!/usr/bin/env python3
"""Скрипт для создания всех таблиц в базе данных"""
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from core.database import Base, engine
from models.user import User, Device
from models.server import Server, ConnectionLog
from models.protocol_stats import ProtocolStats
from models.subscription import Subscription, Plan
from models.payment import Payment
from models.auth_code import AuthCode
from models import UserVpnConnection

def create_tables():
    """Создает все таблицы в базе данных"""
    print("Creating all tables...")
    try:
        Base.metadata.create_all(bind=engine)
        print("✓ All tables created successfully")
        return True
    except Exception as e:
        print(f"✗ Error creating tables: {e}")
        return False

if __name__ == "__main__":
    success = create_tables()
    sys.exit(0 if success else 1)


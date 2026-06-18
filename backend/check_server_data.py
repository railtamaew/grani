#!/usr/bin/env python3
"""
Скрипт для проверки наличия всех необходимых данных у VPN серверов в БД
Проверяет наличие wireguard_public_key, wireguard_port, wireguard_private_key
и supported_protocols
"""

import sys
import os

# Добавляем путь к проекту
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from core.database import Base
from models.server import Server
from core.config import settings
import json

def check_server_data():
    """Проверяет данные всех серверов в БД"""
    # Создаем подключение к БД
    engine = create_engine(settings.DATABASE_URL)
    SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    
    db = SessionLocal()
    
    try:
        # Получаем все серверы
        servers = db.query(Server).all()
        
        if not servers:
            print("⚠️  В базе данных нет серверов")
            return
        
        print(f"📊 Найдено серверов: {len(servers)}\n")
        
        issues_found = False
        
        for server in servers:
            print(f"🔍 Проверка сервера ID={server.id}, name='{server.name}'")
            server_issues = []
            
            # Проверка wireguard_public_key
            if not server.wireguard_public_key or server.wireguard_public_key.strip() == "":
                server_issues.append("❌ Отсутствует wireguard_public_key")
            else:
                print(f"  ✅ wireguard_public_key: {server.wireguard_public_key[:20]}...")
            
            # Проверка wireguard_private_key
            if not server.wireguard_private_key or server.wireguard_private_key.strip() == "":
                server_issues.append("⚠️  Отсутствует wireguard_private_key (может быть нормально для удаленных серверов)")
            else:
                print(f"  ✅ wireguard_private_key: {server.wireguard_private_key[:20]}...")
            
            # Проверка wireguard_port
            wireguard_port = server.wireguard_port or server.port
            if not wireguard_port or wireguard_port <= 0:
                server_issues.append("❌ Отсутствует или неверный wireguard_port")
            else:
                print(f"  ✅ wireguard_port: {wireguard_port}")
            
            # Проверка supported_protocols
            supported_protocols = server.get_supported_protocols()
            if not supported_protocols or len(supported_protocols) == 0:
                server_issues.append("❌ Отсутствует или пустой supported_protocols")
            else:
                print(f"  ✅ supported_protocols: {', '.join(supported_protocols)}")
            
            # Проверка is_active
            if not server.is_active:
                server_issues.append("⚠️  Сервер неактивен (is_active=False)")
            else:
                print(f"  ✅ is_active: {server.is_active}")
            
            # Проверка ip_address
            if not server.ip_address or server.ip_address.strip() == "":
                server_issues.append("❌ Отсутствует ip_address")
            else:
                print(f"  ✅ ip_address: {server.ip_address}")
            
            if server_issues:
                issues_found = True
                print(f"  ⚠️  Проблемы:")
                for issue in server_issues:
                    print(f"     {issue}")
            else:
                print(f"  ✅ Все данные в порядке")
            
            print()
        
        if issues_found:
            print("⚠️  Обнаружены проблемы с данными серверов!")
            print("   Рекомендуется исправить их перед использованием.")
        else:
            print("✅ Все серверы имеют необходимые данные!")
        
    except Exception as e:
        print(f"❌ Ошибка при проверке серверов: {e}")
        import traceback
        traceback.print_exc()
    finally:
        db.close()

if __name__ == "__main__":
    check_server_data()






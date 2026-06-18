#!/usr/bin/env python3
"""
Обновление порта XRay в базе данных
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from core.database import SessionLocal
from sqlalchemy import text

def update_xray_port():
    """Обновляет порт XRay в БД"""
    print(f"\n{'='*60}")
    print(f"  ОБНОВЛЕНИЕ ПОРТА XRAY В БД")
    print(f"{'='*60}\n")
    
    db = SessionLocal()
    try:
        # Обновляем сервер 45.12.132.94
        result = db.execute(text("""
            UPDATE servers 
            SET xray_port = :xray_port
            WHERE ip_address = :ip
        """), {
            "xray_port": 4443,
            "ip": "45.12.132.94"
        })
        
        db.commit()
        
        if result.rowcount > 0:
            print(f"✅ Порт XRay обновлен на 4443 для сервера 45.12.132.94")
        else:
            print("⚠️  Сервер не найден или уже обновлен")
        
        # Проверяем результат
        result = db.execute(text("""
            SELECT id, name, ip_address, xray_port
            FROM servers
            WHERE ip_address = :ip
        """), {"ip": "45.12.132.94"})
        
        server = result.fetchone()
        if server:
            print(f"\n✅ Сервер обновлен:")
            print(f"   ID: {server[0]}")
            print(f"   Name: {server[1]}")
            print(f"   IP: {server[2]}")
            print(f"   XRay Port: {server[3]}")
        
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        db.rollback()
    finally:
        db.close()
    
    print(f"\n{'='*60}\n")

if __name__ == "__main__":
    update_xray_port()


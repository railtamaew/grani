#!/usr/bin/env python3
"""Скрипт для добавления колонки openvpn_port в таблицу servers"""
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

from sqlalchemy import create_engine, text
from core.config import settings

def add_openvpn_port_column():
    engine = create_engine(settings.database_url)
    conn = engine.connect()
    trans = conn.begin()
    
    try:
        conn.execute(text("ALTER TABLE servers ADD COLUMN IF NOT EXISTS openvpn_port INTEGER"))
        trans.commit()
        print("✅ Колонка openvpn_port добавлена")
        return True
    except Exception as e:
        trans.rollback()
        print(f"❌ Ошибка: {e}")
        return False
    finally:
        conn.close()

if __name__ == "__main__":
    print("Добавление колонки openvpn_port в таблицу servers...")
    add_openvpn_port_column()







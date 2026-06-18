#!/usr/bin/env python3
"""Скрипт для добавления недостающих полей в таблицу servers"""
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

from sqlalchemy import create_engine, text
from core.config import settings

def add_missing_columns():
    engine = create_engine(settings.database_url)
    conn = engine.connect()
    trans = conn.begin()
    
    try:
        # Добавляем недостающие поля
        columns_to_add = [
            ("ssh_host", "VARCHAR"),
            ("ssh_port", "INTEGER DEFAULT 22"),
            ("ssh_user", "VARCHAR DEFAULT 'root'"),
            ("ssh_key_path", "VARCHAR"),
            ("ssh_key_content", "TEXT"),
            ("wireguard_config_path", "VARCHAR DEFAULT '/etc/wireguard/wg0.conf'"),
            ("wireguard_interface", "VARCHAR DEFAULT 'wg0'"),
            ("xray_config_path", "VARCHAR DEFAULT '/etc/xray/config.json'"),
            ("is_local", "BOOLEAN DEFAULT FALSE"),
        ]
        
        for col_name, col_type in columns_to_add:
            try:
                conn.execute(text(f"ALTER TABLE servers ADD COLUMN IF NOT EXISTS {col_name} {col_type}"))
                print(f"✅ Поле {col_name} добавлено")
            except Exception as e:
                print(f"⚠️  Поле {col_name}: {e}")
        
        trans.commit()
        print("\n✅ Все поля успешно добавлены")
        return True
    except Exception as e:
        trans.rollback()
        print(f"❌ Ошибка: {e}")
        return False
    finally:
        conn.close()

if __name__ == "__main__":
    print("Добавление недостающих полей в таблицу servers...")
    add_missing_columns()







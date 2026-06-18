#!/usr/bin/env python3
"""Добавляет колонку device_fingerprint в devices для resolve после переустановки."""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlalchemy import text
from core.database import engine


def apply_migration():
    statements = [
        "ALTER TABLE devices ADD COLUMN IF NOT EXISTS device_fingerprint VARCHAR(255)",
        "CREATE INDEX IF NOT EXISTS ix_devices_user_id_fingerprint ON devices (user_id, device_fingerprint)",
    ]
    with engine.connect() as conn:
        for stmt in statements:
            try:
                conn.execute(text(stmt))
                conn.commit()
                print(f"✓ {stmt[:70]}...")
            except Exception as e:
                err = str(e).lower()
                if "already exists" in err or "duplicate" in err:
                    print(f"⚠ Пропущено (уже есть): {stmt[:50]}...")
                    conn.rollback()
                else:
                    print(f"✗ {e}")
                    conn.rollback()
                    return False
    print("✓ Миграция device_fingerprint применена.")
    return True


if __name__ == "__main__":
    success = apply_migration()
    sys.exit(0 if success else 1)

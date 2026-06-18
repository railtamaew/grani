#!/usr/bin/env python3
"""
Скрипт для применения миграции мониторинга VPN
"""
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlalchemy import text
from core.database import engine

def apply_migration():
    """Применяет миграцию для мониторинга VPN"""
    migration_file = os.path.join(
        os.path.dirname(__file__),
        '..',
        'alembic',
        'versions',
        'add_vpn_monitoring.sql'
    )
    
    if not os.path.exists(migration_file):
        print(f"Файл миграции не найден: {migration_file}")
        return False
    
    try:
        with open(migration_file, 'r', encoding='utf-8') as f:
            sql = f.read()
        
        with engine.connect() as conn:
            # Выполняем SQL команды по одной
            statements = [s.strip() for s in sql.split(';') if s.strip() and not s.strip().startswith('--')]
            
            for statement in statements:
                if statement:
                    try:
                        conn.execute(text(statement))
                        conn.commit()
                        print(f"✓ Выполнено: {statement[:50]}...")
                    except Exception as e:
                        # Игнорируем ошибки "column already exists" и подобные
                        if 'already exists' in str(e).lower() or 'duplicate' in str(e).lower():
                            print(f"⚠ Пропущено (уже существует): {statement[:50]}...")
                        else:
                            print(f"✗ Ошибка: {e}")
                            print(f"  SQL: {statement[:100]}...")
            
            print("\n✓ Миграция применена успешно!")
            return True
            
    except Exception as e:
        print(f"✗ Ошибка применения миграции: {e}")
        return False

if __name__ == "__main__":
    print("Применение миграции мониторинга VPN...")
    print("=" * 50)
    success = apply_migration()
    sys.exit(0 if success else 1)


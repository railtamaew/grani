#!/usr/bin/env python3
"""Применение миграций БД"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from core.database import engine
from sqlalchemy import text

def apply_migration():
    """Применяет миграцию add_admin_features.sql"""
    migration_file = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        'migrations',
        'add_admin_features.sql'
    )
    
    with open(migration_file, 'r', encoding='utf-8') as f:
        migration_sql = f.read()
    
    # Разделяем на отдельные команды, учитывая многострочные CREATE TABLE
    lines = migration_sql.split('\n')
    statements = []
    current_statement = []
    
    for line in lines:
        line = line.strip()
        if not line or line.startswith('--'):
            continue
        current_statement.append(line)
        if line.endswith(';'):
            stmt = ' '.join(current_statement).rstrip(';')
            if stmt:
                statements.append(stmt)
            current_statement = []
    
    # Добавляем оставшийся statement, если есть
    if current_statement:
        stmt = ' '.join(current_statement)
        if stmt:
            statements.append(stmt)
    
    with engine.connect() as conn:
        trans = conn.begin()
        try:
            for statement in statements:
                if statement:
                    try:
                        conn.execute(text(statement + ';'))
                        print(f"✅ Выполнено: {statement[:80]}...")
                        conn.commit()
                        trans = conn.begin()  # Начинаем новую транзакцию
                    except Exception as e:
                        # Игнорируем ошибки "column already exists" или "table already exists"
                        error_str = str(e).lower()
                        if 'already exists' in error_str or 'duplicate' in error_str or 'if not exists' in statement.lower():
                            print(f"⚠️  Пропущено (уже существует): {statement[:80]}...")
                            conn.rollback()
                            trans = conn.begin()
                        else:
                            print(f"❌ Ошибка: {statement[:80]}...")
                            print(f"   {e}")
                            raise
            
            trans.commit()
            print("\n✅ Миграция применена успешно!")
        except Exception as e:
            trans.rollback()
            print(f"\n❌ Ошибка при применении миграции: {e}")
            raise

if __name__ == "__main__":
    apply_migration()


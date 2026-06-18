#!/usr/bin/env python3
"""Включает все протоколы на всех серверах для тестирования"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from sqlalchemy import text
from core.database import SessionLocal

db = SessionLocal()
try:
    conn = db.connection()
    
    # Получаем все активные серверы
    result = conn.execute(text("""
        SELECT id, name 
        FROM servers 
        WHERE is_active = true
    """))
    servers = result.fetchall()
    
    print('📋 Включение всех протоколов на серверах...')
    print('='*80)
    
    for server_id, name in servers:
        print(f'\nСервер ID: {server_id} | {name}')
        
        # Включаем все флаги протоколов
        conn.execute(text("""
            UPDATE servers 
            SET graniwg_enabled = true,
                cloak_enabled = true,
                reality_enabled = true
            WHERE id = :server_id
        """), {'server_id': server_id})
        
        print(f'   ✅ Включены: GRANIWG, OpenVPN Cloak, XRay Reality')
    
    db.commit()
    print('\n✅ Все протоколы включены на всех серверах!')
    
finally:
    db.close()



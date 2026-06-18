#!/usr/bin/env python3
"""Добавляет поддерживаемые протоколы к серверам для тестирования.

Примечание: openvpn_cloak находится в архиве и намеренно не добавляется.
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from sqlalchemy import text
from core.database import SessionLocal
import json

db = SessionLocal()
try:
    conn = db.connection()
    
    # Получаем все активные серверы
    result = conn.execute(text("""
        SELECT id, name, supported_protocols 
        FROM servers 
        WHERE is_active = true
    """))
    servers = result.fetchall()
    
    print('📋 Обновление протоколов на серверах...')
    print('='*80)
    
    # Протоколы для тестирования (WireGuard/GRANIWG + Xray).
    # openvpn_cloak находится в архиве и намеренно не добавляется.
    all_protocols = [
        'wireguard',
        'graniwg',
        'xray_vless',
        'xray_vmess',
        'xray_reality',
    ]
    
    for server_id, name, current_protocols in servers:
        print(f'\nСервер ID: {server_id} | {name}')
        print(f'   Текущие протоколы: {current_protocols}')
        
        # Обновляем протоколы
        protocols_json = json.dumps(all_protocols)
        
        conn.execute(text("""
            UPDATE servers 
            SET supported_protocols = :protocols
            WHERE id = :server_id
        """), {
            'protocols': protocols_json,
            'server_id': server_id
        })
        
        print(f'   ✅ Обновлено: {all_protocols}')
    
    db.commit()
    print('\n✅ Все серверы обновлены!')
    print(f'   Добавлены протоколы: {", ".join(all_protocols)}')
    
finally:
    db.close()



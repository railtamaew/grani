#!/usr/bin/env python3
"""Проверка протоколов серверов"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from sqlalchemy import text
from core.database import SessionLocal
import json

db = SessionLocal()
try:
    conn = db.connection()
    result = conn.execute(text("""
        SELECT id, name, supported_protocols, graniwg_enabled, cloak_enabled, reality_enabled 
        FROM servers 
        WHERE is_active = true
    """))
    servers = result.fetchall()
    
    print('📋 Серверы в базе данных:')
    print('='*80)
    for server in servers:
        server_id, name, protocols, graniwg, cloak, reality = server
        print(f'\nID: {server_id} | {name}')
        print(f'   supported_protocols (raw): {protocols}')
        print(f'   Тип: {type(protocols)}')
        
        # Парсим протоколы
        if protocols is None:
            parsed = ["wireguard"]
        elif isinstance(protocols, str):
            try:
                parsed = json.loads(protocols)
            except:
                parsed = [protocols] if protocols else ["wireguard"]
        elif isinstance(protocols, list):
            parsed = protocols
        else:
            parsed = ["wireguard"]
        
        print(f'   Парсированные протоколы: {parsed}')
        print(f'   graniwg_enabled: {graniwg}')
        print(f'   reality_enabled: {reality}')
        
        # Определяем, какие протоколы должны быть доступны
        available_protocols = []
        if 'wireguard' in parsed or 'graniwg' in parsed:
            available_protocols.append('wireguard')
        if 'graniwg' in parsed or graniwg:
            available_protocols.append('graniwg')
        if 'xray_vless' in parsed:
            available_protocols.append('xray_vless')
        if 'xray_vmess' in parsed:
            available_protocols.append('xray_vmess')
        if 'xray_reality' in parsed or reality:
            available_protocols.append('xray_reality')
        # openvpn_cloak находится в архиве и намеренно не показывается
        
        print(f'   ✅ Должны быть доступны: {available_protocols}')
finally:
    db.close()



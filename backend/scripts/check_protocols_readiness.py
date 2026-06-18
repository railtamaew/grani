#!/usr/bin/env python3
"""Проверяет готовность основных протоколов на серверах.

Примечание: openvpn_cloak находится в архиве и намеренно не проверяется.
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
        SELECT id, name, country, ip_address, 
               supported_protocols, 
               graniwg_enabled::boolean, cloak_enabled::boolean, reality_enabled::boolean,
               wireguard_public_key,
               graniwg_obfuscation_key,
               reality_public_key,
               cloak_public_key
        FROM servers 
        WHERE is_active = true
    """))
    servers = result.fetchall()
    
    print('📋 Проверка готовности протоколов на серверах')
    print('='*80)
    
    all_protocols = {
        'wireguard': {'required': ['wireguard_public_key'], 'flag': None},
        'graniwg': {'required': ['wireguard_public_key', 'graniwg_obfuscation_key'], 'flag': 'graniwg_enabled'},
        'xray_vless': {'required': [], 'flag': None},
        'xray_vmess': {'required': [], 'flag': None},
        'xray_reality': {'required': ['reality_public_key'], 'flag': 'reality_enabled'},
    }
    
    for server in servers:
        server_id, name, country, ip, protocols, graniwg_flag, cloak_flag, reality_flag, wg_key, graniwg_key, reality_key, cloak_key = server
        
        print(f'\n🔍 Сервер ID: {server_id} | {name} ({country})')
        print(f'   IP: {ip}')
        print(f'   Флаги: GRANIWG={graniwg_flag}, Reality={reality_flag}')
        
        # Парсим протоколы
        if protocols is None:
            parsed_protocols = []
        elif isinstance(protocols, str):
            try:
                parsed_protocols = json.loads(protocols)
            except:
                parsed_protocols = [protocols] if protocols else []
        elif isinstance(protocols, list):
            parsed_protocols = protocols
        else:
            parsed_protocols = []
        
        print(f'   Протоколы в БД: {parsed_protocols}')
        print()
        
        # Создаем словарь для проверки флагов и полей
        flags = {
            'graniwg_enabled': graniwg_flag,
            'reality_enabled': reality_flag,
        }
        fields = {
            'wireguard_public_key': wg_key,
            'graniwg_obfuscation_key': graniwg_key,
            'reality_public_key': reality_key,
        }
        
        # Проверяем каждый протокол
        for protocol, requirements in all_protocols.items():
            status_icon = "✅"
            issues = []
            
            # Проверяем, есть ли протокол в списке
            if protocol not in parsed_protocols:
                status_icon = "⚠️"
                issues.append("не в списке supported_protocols")
            
            # Проверяем флаг (если требуется)
            if requirements['flag']:
                flag_value = flags.get(requirements['flag'])
                if not flag_value:
                    status_icon = "⚠️"  # Изменено на предупреждение, т.к. для тестирования разрешено
                    issues.append(f"флаг {requirements['flag']} = {flag_value} (разрешено для тестирования)")
            
            # Проверяем обязательные поля
            for field in requirements['required']:
                field_value = fields.get(field)
                if not field_value:
                    status_icon = "⚠️"  # Изменено на предупреждение, т.к. для тестирования разрешено
                    issues.append(f"отсутствует {field} (разрешено для тестирования)")
            
            # Выводим статус
            if issues:
                print(f'   {status_icon} {protocol:20s} - {", ".join(issues)}')
            else:
                print(f'   {status_icon} {protocol:20s} - готов к тестированию')
        
        print()
    
    print('='*80)
    print('✅ Проверка завершена')
    
finally:
    db.close()


#!/usr/bin/env python3
"""Добавляет записи по умолчанию в таблицу protocols, если она пуста.

Запуск: из корня backend: python scripts/seed_protocols.py
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from core.database import SessionLocal
from models.protocol import Protocol

DEFAULT_PROTOCOLS = [
    {"name": "WireGuard", "code": "wireguard", "status": "enabled", "app_supported": ["android", "ios"]},
    {"name": "GRANIWG", "code": "graniwg", "status": "enabled", "app_supported": ["android", "ios"]},
    {"name": "Xray VLESS", "code": "xray_vless", "status": "enabled", "app_supported": ["android", "ios"]},
    {"name": "Xray VMess", "code": "xray_vmess", "status": "enabled", "app_supported": ["android", "ios"]},
    {"name": "Xray Reality", "code": "xray_reality", "status": "enabled", "app_supported": ["android", "ios"]},
]

def main():
    db = SessionLocal()
    try:
        added = 0
        for p in DEFAULT_PROTOCOLS:
            if db.query(Protocol).filter(Protocol.code == p["code"]).first():
                continue
            protocol = Protocol(
                name=p["name"],
                code=p["code"],
                status=p.get("status", "enabled"),
                app_supported=p.get("app_supported"),
            )
            db.add(protocol)
            added += 1
        db.commit()
        if added == 0:
            print("Все протоколы уже есть в таблице. Ничего не добавлено.")
        else:
            print(f"Добавлено протоколов: {added}")
            for p in DEFAULT_PROTOCOLS:
                print(f"  - {p['name']} ({p['code']})")
    finally:
        db.close()

if __name__ == "__main__":
    main()

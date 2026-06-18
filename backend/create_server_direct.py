#!/usr/bin/env python3
"""Создание сервера напрямую через SQL"""
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

from sqlalchemy import create_engine, text
from core.config import settings

def create_server_direct():
    ssh_password = os.getenv("SSH_PASSWORD")
    if not ssh_password:
        print("✗ Задайте SSH_PASSWORD через переменную окружения.")
        return None

    engine = create_engine(settings.database_url)
    conn = engine.connect()
    trans = conn.begin()

    try:
        # Проверяем существующий сервер
        result = conn.execute(text("SELECT id FROM servers WHERE ip_address = :ip"), {"ip": "45.12.132.94"})
        existing = result.fetchone()
        if existing:
            print(f"⚠️  Сервер с IP 45.12.132.94 уже существует (ID: {existing[0]})")
            print(f"   Обновляем данные сервера...")
            # Обновляем данные существующего сервера
            import json
            protocols_json = json.dumps(["wireguard"])
            conn.execute(text("""
                UPDATE servers SET
                    name = :name,
                    country = :country,
                    city = :city,
                    ssh_host = :ssh_host,
                    ssh_port = :ssh_port,
                    ssh_user = :ssh_user,
                    ssh_password = :ssh_password,
                    wireguard_port = :wg_port,
                    supported_protocols = CAST(:protocols AS jsonb),
                    is_local = :is_local,
                    is_active = true
                WHERE ip_address = :ip
            """), {
                "name": "HU-BUD-01",
                "ip": "45.12.132.94",
                "country": "Венгрия",
                "city": "Будапешт",
                "ssh_host": "45.12.132.94",
                "ssh_port": 22,
                "ssh_user": "root",
                "ssh_password": ssh_password,
                "wg_port": 51820,
                "protocols": protocols_json,
                "is_local": False
            })
            trans.commit()
            print(f"✅ Сервер обновлен успешно!")
            return existing[0]
        
        # Создаем сервер напрямую через SQL
        import json
        protocols_json = json.dumps(["wireguard"])
        result = conn.execute(text("""
            INSERT INTO servers (
                name, ip_address, country, city,
                ssh_host, ssh_port, ssh_user, ssh_password,
                wireguard_port, supported_protocols, is_local,
                is_active, max_users, current_users
            ) VALUES (
                :name, :ip, :country, :city,
                :ssh_host, :ssh_port, :ssh_user, :ssh_password,
                :wg_port, CAST(:protocols AS jsonb), :is_local,
                true, 1000, 0
            ) RETURNING id
        """), {
            "name": "HU-BUD-01",
            "ip": "45.12.132.94",
            "country": "Венгрия",
            "city": "Будапешт",
            "ssh_host": "45.12.132.94",
            "ssh_port": 22,
            "ssh_user": "root",
            "ssh_password": ssh_password,
            "wg_port": 51820,
            "protocols": protocols_json,
            "is_local": False
        })
        server_id = result.fetchone()[0]
        
        result = conn.execute(text("SELECT id FROM servers WHERE ip_address = :ip"), {"ip": "45.12.132.94"})
        server_id = result.fetchone()[0]
        
        trans.commit()
        print(f"✅ Сервер создан успешно!")
        print(f"   ID: {server_id}")
        return server_id
    except Exception as e:
        trans.rollback()
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return None
    finally:
        conn.close()

if __name__ == "__main__":
    create_server_direct()


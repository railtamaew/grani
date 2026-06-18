#!/usr/bin/env python3
"""
Синхронизация REALITY конфигурации на всех серверах.
Обновляет realitySettings и flow клиентов.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from core.database import SessionLocal
from models.server import Server
from services.xray_manager import XrayManager


def fix_reality_configs() -> int:
    db = SessionLocal()
    try:
        servers = db.query(Server).filter(Server.reality_enabled == True).all()
        if not servers:
            print("REALITY серверы не найдены")
            return 0

        updated = 0
        for server in servers:
            xray_manager = XrayManager(server)
            result = xray_manager.ensure_reality_server_config(server)
            if result.get("success"):
                updated += 1
                print(
                    f"✅ Server {server.id} ({server.ip_address}): "
                    f"inbound_created={result.get('created_inbound')}, "
                    f"inbound_ok={result.get('updated_inbound')}, "
                    f"clients_updated={result.get('updated_clients')}, "
                    f"total_clients={result.get('total_clients')}"
                )
            else:
                print(f"❌ Server {server.id} ({server.ip_address}): {result.get('error')}")
        return updated
    finally:
        db.close()


if __name__ == "__main__":
    count = fix_reality_configs()
    print(f"Готово. Обновлено серверов: {count}")

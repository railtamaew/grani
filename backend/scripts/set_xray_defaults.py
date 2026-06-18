#!/usr/bin/env python3
"""
Заполняет Xray-поля по умолчанию для серверов.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from core.database import SessionLocal
from models.server import Server


DEFAULT_XRAY_PORT = 4443
DEFAULT_XRAY_CONFIG_PATH = "/etc/xray/config.json"


def _has_reality_fields(server: Server) -> bool:
    return any([
        server.reality_public_key,
        server.reality_private_key,
        server.reality_short_id,
        server.reality_dest,
        server.reality_sni,
        server.reality_server_name,
    ])


def main() -> int:
    db = SessionLocal()
    updated = 0
    try:
        servers = db.query(Server).all()
        print(f"Найдено серверов: {len(servers)}")

        for server in servers:
            changed = False

            if server.xray_port is None:
                server.xray_port = DEFAULT_XRAY_PORT
                changed = True

            if not server.xray_config_path:
                server.xray_config_path = DEFAULT_XRAY_CONFIG_PATH
                changed = True

            if server.reality_enabled is None:
                server.reality_enabled = _has_reality_fields(server)
                changed = True

            if changed:
                updated += 1
                print(
                    f"Сервер {server.id} ({server.name}): "
                    f"xray_port={server.xray_port}, "
                    f"xray_config_path={server.xray_config_path}, "
                    f"reality_enabled={server.reality_enabled}"
                )

        if updated:
            db.commit()
            print(f"Обновлено серверов: {updated}")
        else:
            print("Обновлений не требуется")
        return 0
    except Exception as exc:
        db.rollback()
        print(f"Ошибка обновления Xray-полей: {exc}")
        return 1
    finally:
        db.close()


if __name__ == "__main__":
    raise SystemExit(main())

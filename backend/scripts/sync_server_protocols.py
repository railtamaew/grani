#!/usr/bin/env python3
"""
Синхронизирует supported_protocols на серверах,
если поле пустое или отсутствует.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from core.database import SessionLocal
from models.server import Server


def main() -> int:
    db = SessionLocal()
    updated = 0
    try:
        servers = db.query(Server).all()
        print(f"Найдено серверов: {len(servers)}")

        for server in servers:
            protocols = server.supported_protocols
            is_empty = protocols is None or protocols == [] or protocols == ""  # noqa: PLC1901
            if not is_empty:
                continue

            computed = server.get_supported_protocols()
            server.set_supported_protocols(computed)
            updated += 1
            print(
                f"Сервер {server.id} ({server.name}): "
                f"supported_protocols={computed}"
            )

        if updated:
            db.commit()
            print(f"Обновлено серверов: {updated}")
        else:
            print("Обновлений не требуется")
        return 0
    except Exception as exc:
        db.rollback()
        print(f"Ошибка синхронизации протоколов: {exc}")
        return 1
    finally:
        db.close()


if __name__ == "__main__":
    raise SystemExit(main())

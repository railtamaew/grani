#!/usr/bin/env python3
"""
Одноразово: для HU-BUD-01 (45.12.132.94) выставить xray_port = REALITY (2053).
Дальше: `patch_hungary_xray_reality_port.py` или полный rollout `hungary_api_and_reality_rollout.py`.

  python3 backend/scripts/migrate_hungary_reality_port_to_2053.py
  (подхватывает backend/.env автоматически; при необходимости GRANI_BACKEND_ENV_FILE)
"""
import os
import sys

_scripts_dir = os.path.dirname(os.path.abspath(__file__))
if _scripts_dir not in sys.path:
    sys.path.insert(0, _scripts_dir)
from script_env import ensure_script_environment

ensure_script_environment()

from sqlalchemy import text
from core.database import SessionLocal
from core.constants import XRAY_REALITY_DEFAULT_PORT


def main():
    db = SessionLocal()
    try:
        r = db.execute(
            text("""
                UPDATE servers
                SET xray_port = :p
                WHERE (ip_address = '45.12.132.94' OR name ILIKE '%HU-BUD%')
                  AND (xray_port IS NULL OR xray_port = 443)
                RETURNING id, name, xray_port
            """),
            {"p": XRAY_REALITY_DEFAULT_PORT},
        )
        rows = r.fetchall()
        db.commit()
        if not rows:
            print("Нет строк для обновления (уже не NULL/443 или сервер не найден).")
            return 0
        for row in rows:
            print(f"OK: server id={row[0]} name={row[1]} xray_port={row[2]}")
        print(f"\nДальше: patch_hungary_xray_reality_port.py или hungary_api_and_reality_rollout.py")
        return 0
    except Exception as e:
        db.rollback()
        print(f"Ошибка: {e}")
        return 1
    finally:
        db.close()


if __name__ == "__main__":
    sys.exit(main())

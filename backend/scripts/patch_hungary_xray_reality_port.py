#!/usr/bin/env python3
"""
По SSH на HU-BUD-01: переносит inbound VLESS+REALITY с порта 443 на 2053,
обновляет servers.xray_port в БД, перезагружает xray.

  python3 backend/scripts/patch_hungary_xray_reality_port.py

Ключ SSH из БД (RemoteVPNManager). Идемпотентно: если REALITY уже на 2053 — только БД/sync.
"""
from __future__ import annotations

import json
import os
import sys

_scripts_dir = os.path.dirname(os.path.abspath(__file__))
if _scripts_dir not in sys.path:
    sys.path.insert(0, _scripts_dir)
from script_env import ensure_script_environment

ensure_script_environment()

from sqlalchemy import text
from core.database import SessionLocal
from models.server import Server
from services.remote_vpn_manager import RemoteVPNManager
from core.constants import XRAY_DEFAULT_CONFIG_PATH, XRAY_REALITY_DEFAULT_PORT


def _reality_inbound(ib: dict) -> bool:
    if ib.get("protocol") != "vless":
        return False
    ss = ib.get("streamSettings") or {}
    return ss.get("security") == "reality"


def patch_config(config: dict) -> tuple[dict, bool]:
    changed = False
    for ib in config.get("inbounds", []) or []:
        if not _reality_inbound(ib):
            continue
        p = ib.get("port")
        if p == 443:
            ib["port"] = XRAY_REALITY_DEFAULT_PORT
            changed = True
    return config, changed


def main() -> int:
    db = SessionLocal()
    try:
        server = (
            db.query(Server)
            .filter(
                (Server.ip_address == "45.12.132.94")
                | (Server.name.ilike("%HU-BUD%"))
            )
            .first()
        )
        if not server:
            print("❌ Сервер 45.12.132.94 / HU-BUD не найден в БД")
            return 1

        rm = RemoteVPNManager()
        if not rm.ssh_manager:
            print("❌ SSHManager недоступен")
            return 1

        cfg = rm.get_ssh_config(server)
        host, port, user = cfg["host"], cfg["port"], cfg["username"]
        key_path = cfg.get("key_path")
        key_content = cfg.get("key_content")
        password = cfg.get("password")

        remote_path = (
            getattr(server, "xray_config_path", None) or XRAY_DEFAULT_CONFIG_PATH
        )
        print(f"Чтение {remote_path} на {host}...")
        raw = rm.ssh_manager.download_content(
            host, remote_path, port, user, key_path, key_content, password
        )
        if raw is None:
            print("❌ Не удалось прочитать конфиг Xray")
            return 1

        try:
            config = json.loads(raw)
        except json.JSONDecodeError as e:
            print(f"❌ JSON: {e}")
            return 1

        config, changed = patch_config(config)
        if not changed:
            print("✅ Inbound REALITY уже не на 443 (или не найден)")
        else:
            print(
                f"Запись REALITY 443 → {XRAY_REALITY_DEFAULT_PORT}, загрузка на сервер..."
            )
            new_raw = json.dumps(config, indent=2, ensure_ascii=False) + "\n"
            ok = rm.ssh_manager.upload_content_atomic(
                host,
                new_raw,
                remote_path,
                port,
                user,
                key_path,
                key_content,
                password,
            )
            if not ok:
                print(
                    "⚠️ Атомарная запись не удалась (права/rename), пробуем обычную SFTP-запись..."
                )
                ok = rm.ssh_manager.upload_content(
                    host,
                    new_raw,
                    remote_path,
                    port,
                    user,
                    key_path,
                    key_content,
                    password,
                )
            if not ok:
                print("❌ Не удалось записать конфиг")
                return 1
            rm.ssh_manager.command_timeout = 60
            test_cmd = (
                f"xray run -test -c {remote_path} && "
                "(systemctl reload xray-v2 || systemctl restart xray-v2)"
            )
            r = rm.ssh_manager.execute_command(
                host,
                test_cmd,
                port,
                user,
                key_path,
                key_content,
                password,
            )
            if not r.get("success"):
                print(f"⚠️ reload xray: {r.get('stderr', r.get('stdout', ''))[:500]}")
            else:
                print("✅ xray reload выполнен")

        db.execute(
            text("UPDATE servers SET xray_port = :p WHERE id = :id"),
            {"p": XRAY_REALITY_DEFAULT_PORT, "id": server.id},
        )
        db.commit()
        print(f"✅ БД: servers.xray_port = {XRAY_REALITY_DEFAULT_PORT} (id={server.id})")
        return 0
    except Exception as e:
        print(f"❌ {e}")
        import traceback

        traceback.print_exc()
        db.rollback()
        return 1
    finally:
        db.close()


if __name__ == "__main__":
    sys.exit(main())

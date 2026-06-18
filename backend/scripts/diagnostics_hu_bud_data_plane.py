#!/usr/bin/env python3
"""
Read-only проверка data-plane ноды (план §4–5): SSH только через RemoteVPNManager + ключ из БД.

Требуется: DATABASE_URL (и .env через script_env), paramiko, запись Server в БД с SSH-ключом.

Не логирует ssh_key_content. Не изменяет состояние ноды.

Использование:
  cd /opt/grani/backend && PYTHONPATH=/opt/grani/backend python3 scripts/diagnostics_hu_bud_data_plane.py
  python3 scripts/diagnostics_hu_bud_data_plane.py --server-name HU-BUD-01 --journal-lines 120
"""
from __future__ import annotations

import argparse
import os
import sys

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_BACKEND_ROOT = os.path.abspath(os.path.join(_SCRIPT_DIR, ".."))
if _BACKEND_ROOT not in sys.path:
    sys.path.insert(0, _BACKEND_ROOT)

# Загрузка .env до SessionLocal
import script_env  # noqa: E402

script_env.ensure_script_environment()

from core.database import SessionLocal  # noqa: E402
from models.server import Server  # noqa: E402
from services.remote_vpn_manager import RemoteVPNManager  # noqa: E402


def _run(rm: RemoteVPNManager, cfg: dict, cmd: str, title: str) -> None:
    print(f"\n=== {title} ===")
    if not rm.ssh_manager:
        print("SSHManager недоступен (paramiko).")
        return
    r = rm.ssh_manager.execute_command(
        cfg["host"],
        cmd,
        cfg["port"],
        cfg["username"],
        cfg.get("key_path"),
        cfg.get("key_content"),
        cfg.get("password"),
    )
    out = (r.get("stdout") or "") + (r.get("stderr") or "")
    print(out.rstrip() or "(пусто)")
    if not r.get("success"):
        print(f"(exit/success={r.get('success')})")


def main() -> int:
    p = argparse.ArgumentParser(description="Read-only HU-BUD / VPN node checks via DB SSH config.")
    p.add_argument("--server-name", default="HU-BUD-01", help="Имя записи в таблице servers")
    p.add_argument("--journal-lines", type=int, default=80, help="Строк journalctl -u xray-v2")
    args = p.parse_args()

    db = SessionLocal()
    try:
        server = db.query(Server).filter(Server.name == args.server_name).first()
        if not server:
            print(f"Сервер {args.server_name!r} не найден в БД", file=sys.stderr)
            return 1

        rm = RemoteVPNManager()
        cfg = rm.get_ssh_config(server)
        if not cfg:
            print("Не удалось получить SSH-конфиг", file=sys.stderr)
            return 1

        host = cfg.get("host") or getattr(server, "ip_address", "?")
        print(f"Сервер: {getattr(server, 'name', args.server_name)} host={host} (read-only команды)")

        n = max(20, min(args.journal_lines, 500))
        _run(rm, cfg, "systemctl is-active xray-v2 2>/dev/null || true", "systemd: is-active xray")
        _run(
            rm,
            cfg,
            "systemctl status xray-v2 --no-pager 2>/dev/null | head -50 || true",
            "systemd: status xray (head)",
        )
        _run(
            rm,
            cfg,
            "ss -tlnp 2>/dev/null | grep -E ':443|:4443|:8443|:2053|:10085' || ss -tlnp 2>/dev/null | head -40",
            "Listening ports (filtered)",
        )
        _run(
            rm,
            cfg,
            f"journalctl -u xray-v2 --no-pager -n {n} 2>/dev/null || true",
            f"journalctl -u xray-v2 (last {n} lines)",
        )
        _run(
            rm,
            cfg,
            "test -f /usr/local/etc/xray/config.json && echo OK: /usr/local/etc/xray/config.json "
            "|| echo MISSING: /usr/local/etc/xray/config.json",
            "config.json presence",
        )
        _run(
            rm,
            cfg,
            "tail -n 40 /var/log/xray/error.log 2>/dev/null || echo 'no /var/log/xray/error.log'",
            "xray error.log tail",
        )
        _run(
            rm,
            cfg,
            "tail -n 20 /var/log/xray/access.log 2>/dev/null || echo 'no /var/log/xray/access.log'",
            "xray access.log tail",
        )
    finally:
        db.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

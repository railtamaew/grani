#!/usr/bin/env python3
"""
Установка systemd drop-in для systemctl reload xray-v2 (ExecReload + SIGHUP).
Сервер из БД по имени; SSH через RemoteVPNManager (ключ из servers).
"""
from __future__ import annotations

import argparse
import base64
import sys

sys.path.insert(0, __import__("os").path.join(__import__("os").path.dirname(__file__), ".."))

from core.database import SessionLocal  # noqa: E402
from models.server import Server  # noqa: E402
from services.remote_vpn_manager import RemoteVPNManager  # noqa: E402

DROPIN_PATH = "/etc/systemd/system/xray.service.d/grani-exec-reload.conf"
DROPIN_BODY = """[Service]
ExecReload=
ExecReload=/usr/local/bin/xray run -test -config=/usr/local/etc/xray/config.json
ExecReload=/bin/kill -HUP $MAINPID
"""


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--name", default="HU-BUD-01", help="Server name in DB")
    args = p.parse_args()

    db = SessionLocal()
    try:
        server = db.query(Server).filter(Server.name == args.name).first()
        if not server:
            print(f"ERROR: server name={args.name!r} not found")
            return 1
    finally:
        db.close()

    rm = RemoteVPNManager()
    if not rm.ssh_manager:
        print("ERROR: SSHManager unavailable")
        return 1

    cfg = rm.get_ssh_config(server)
    host = cfg["host"]
    port = cfg["port"]
    user = cfg["username"]
    key_path = cfg.get("key_path")
    key_content = cfg.get("key_content")
    password = cfg.get("password")

    def run(cmd: str) -> dict:
        return rm.ssh_manager.execute_command(
            host, cmd, port, user, key_path, key_content, password
        )

    r0 = run("mkdir -p /etc/systemd/system/xray.service.d")
    if not r0.get("success"):
        print("mkdir failed:", r0.get("stderr", r0))
        return 1

    b64 = base64.standard_b64encode(DROPIN_BODY.encode("utf-8")).decode("ascii")
    r1 = run(
        f"echo {b64} | base64 -d > {DROPIN_PATH} && chmod 644 {DROPIN_PATH}"
    )
    if not r1.get("success"):
        print("write drop-in failed:", r1.get("stderr", r1))
        return 1

    r2 = run("systemctl daemon-reload")
    if not r2.get("success"):
        print("daemon-reload failed:", r2.get("stderr", r2))
        return 1

    r3 = run("systemctl reload xray-v2")
    if not r3.get("success"):
        print("reload xray failed (exit):", r3.get("exit_status"), r3.get("stderr", ""))
        r4 = run("systemctl show xray -p ExecReload --no-pager")
        print("ExecReload property:", r4.get("stdout", ""))
        return 1

    r5 = run("systemctl is-active xray-v2")
    active = (r5.get("stdout") or "").strip()
    if active != "active":
        print("xray was not active after reload; starting…")
        r6 = run("systemctl start xray-v2")
        if not r6.get("success"):
            print("systemctl start xray-v2 failed:", r6.get("stderr", r6))
            return 1
        r5 = run("systemctl is-active xray-v2")
        active = (r5.get("stdout") or "").strip()
    print("xray is-active:", active)
    print("OK: drop-in installed at", DROPIN_PATH, "and systemctl reload xray-v2 succeeded")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

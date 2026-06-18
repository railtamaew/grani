#!/usr/bin/env python3
"""
Setup xray-v2 systemd runtime on a remote server and switch traffic from xray to xray-v2.

Default mode is dry-run. Use --apply to execute remote changes.
"""
from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime
from sqlalchemy import text

_BACKEND_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if _BACKEND_ROOT not in sys.path:
    sys.path.insert(0, _BACKEND_ROOT)

from script_env import ensure_script_environment

ensure_script_environment()

from core.database import engine  # noqa: E402
from services.remote_vpn_manager import RemoteVPNManager  # noqa: E402


class ServerProxy:
    def __init__(self, data: dict):
        for key, value in data.items():
            setattr(self, key, value)
        self.is_local = False


def get_server(server_id: int | None, server_ip: str | None) -> ServerProxy:
    if not server_id and not server_ip:
        server_ip = "45.12.132.94"
    where = "id = :v" if server_id else "ip_address = :v"
    value = int(server_id) if server_id else str(server_ip)
    with engine.connect() as conn:
        row = conn.execute(
            text(
                f"""
                SELECT id, name, ip_address, ssh_host, ssh_port, ssh_user,
                       ssh_key_path, ssh_key_content, ssh_password
                FROM servers
                WHERE {where}
                LIMIT 1
                """
            ),
            {"v": value},
        ).fetchone()
    if not row:
        raise RuntimeError("Server not found in DB")
    return ServerProxy(
        {
            "id": row[0],
            "name": row[1],
            "ip_address": row[2],
            "ssh_host": row[3],
            "ssh_port": row[4],
            "ssh_user": row[5],
            "ssh_key_path": row[6],
            "ssh_key_content": row[7],
            "ssh_password": row[8],
        }
    )


def run_remote(rm: RemoteVPNManager, ssh_cfg: dict, command: str) -> dict:
    return rm.ssh_manager.execute_command(
        ssh_cfg["host"],
        command,
        ssh_cfg["port"],
        ssh_cfg["username"],
        ssh_cfg.get("key_path"),
        ssh_cfg.get("key_content"),
        ssh_cfg.get("password"),
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Setup xray-v2 runtime")
    parser.add_argument("--server-id", type=int, default=None)
    parser.add_argument("--server-ip", type=str, default=None)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--legacy-unit", type=str, default="xray")
    parser.add_argument("--v2-unit", type=str, default="xray-v2")
    parser.add_argument("--legacy-config", type=str, default="/usr/local/etc/xray/config.json")
    parser.add_argument("--v2-config", type=str, default="/usr/local/etc/xray/config-v2.json")
    parser.add_argument("--backup-root", type=str, default="/root/grani-backups/xray-v2-setup")
    args = parser.parse_args()

    server = get_server(args.server_id, args.server_ip)
    rm = RemoteVPNManager()
    if not rm.ssh_manager:
        raise RuntimeError("SSH manager unavailable")
    ssh_cfg = rm.get_ssh_config(server)

    ts = datetime.utcnow().strftime("%Y%m%d-%H%M%S")
    backup_dir = f"{args.backup_root}/{server.ip_address}-{ts}"
    print(f"Server: {server.name} ({server.ip_address})")
    print(f"Mode: {'APPLY' if args.apply else 'DRY-RUN'}")
    print(f"Backup dir: {backup_dir}")

    unit_body = f"""[Unit]
Description=Xray Service V2
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config {args.v2_config}
ExecReload=/usr/local/bin/xray run -test -config {args.v2_config}
Restart=on-failure
RestartPreventExitStatus=23
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
"""
    unit_escaped = unit_body.replace("'", "'\"'\"'")

    commands = [
        f"mkdir -p '{backup_dir}'",
        f"cp -a '{args.legacy_config}' '{backup_dir}/config.json.bak' 2>/dev/null || true",
        f"cp -a '/etc/systemd/system/{args.legacy_unit}.service' '{backup_dir}/{args.legacy_unit}.service.bak' 2>/dev/null || true",
        f"cp -a '/lib/systemd/system/{args.legacy_unit}.service' '{backup_dir}/{args.legacy_unit}.service.lib.bak' 2>/dev/null || true",
        f"test -f '{args.v2_config}' || cp -a '{args.legacy_config}' '{args.v2_config}'",
        f"printf '%s' '{unit_escaped}' > /etc/systemd/system/{args.v2_unit}.service",
        "systemctl daemon-reload",
        f"/usr/local/bin/xray run -test -config '{args.v2_config}'",
        f"systemctl stop {args.legacy_unit}",
        f"systemctl enable {args.v2_unit}",
        f"systemctl restart {args.v2_unit}",
        f"systemctl is-active {args.v2_unit}",
        f"ss -tlnp | grep -E 'xray|:443|:4443|:8443|:2053' || true",
    ]

    for cmd in commands:
        print(f"$ {cmd}")
        if not args.apply:
            continue
        res = run_remote(rm, ssh_cfg, cmd)
        out = (res.get("stdout") or "").strip()
        err = (res.get("stderr") or "").strip()
        if out:
            print(out)
        if err:
            print(err)
        if not res.get("success") and "|| true" not in cmd:
            raise RuntimeError(f"Remote command failed: {cmd}")

    print("Done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

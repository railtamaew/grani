#!/usr/bin/env python3
"""
Controlled cleanup of legacy Xray runtime on VPN server.

Default mode is dry-run. Use --apply to execute remote actions.
"""
from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass
from datetime import datetime
from sqlalchemy import text

_BACKEND_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if _BACKEND_ROOT not in sys.path:
    sys.path.insert(0, _BACKEND_ROOT)

from script_env import ensure_script_environment

ensure_script_environment()

from core.database import engine  # noqa: E402
from services.remote_vpn_manager import RemoteVPNManager  # noqa: E402


@dataclass
class ServerProxy:
    id: int
    name: str
    ip_address: str
    ssh_host: str
    ssh_port: int
    ssh_user: str
    ssh_key_path: str | None
    ssh_key_content: str | None
    ssh_password: str | None
    is_local: bool = False


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
        id=row[0],
        name=row[1],
        ip_address=row[2],
        ssh_host=row[3],
        ssh_port=row[4],
        ssh_user=row[5],
        ssh_key_path=row[6],
        ssh_key_content=row[7],
        ssh_password=row[8],
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


def print_step(title: str) -> None:
    print(f"\n== {title} ==")


def main() -> int:
    parser = argparse.ArgumentParser(description="Backup and cleanup legacy Xray runtime")
    parser.add_argument("--server-id", type=int, default=None)
    parser.add_argument("--server-ip", type=str, default=None)
    parser.add_argument("--legacy-unit", type=str, default="xray")
    parser.add_argument("--v2-unit", type=str, default="xray-v2")
    parser.add_argument("--legacy-config", type=str, default="/usr/local/etc/xray/config.json")
    parser.add_argument(
        "--backup-root",
        type=str,
        default="/root/grani-backups/xray-legacy-cleanup",
    )
    parser.add_argument(
        "--allow-stop-without-v2",
        action="store_true",
        help="Allow stopping legacy unit even if v2 unit is not active",
    )
    parser.add_argument("--apply", action="store_true", help="Apply changes on server")
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

    print_step("Create backup directory")
    cmd_backup_dir = f"mkdir -p '{backup_dir}'"
    print(cmd_backup_dir)
    if args.apply:
        print(run_remote(rm, ssh_cfg, cmd_backup_dir)["stdout"])

    print_step("Collect runtime snapshots")
    snapshots = [
        f"systemctl list-unit-files 'xray*' > '{backup_dir}/systemd-units.txt' 2>&1",
        f"systemctl status {args.legacy_unit} --no-pager > '{backup_dir}/legacy-status.txt' 2>&1 || true",
        f"systemctl status {args.v2_unit} --no-pager > '{backup_dir}/v2-status.txt' 2>&1 || true",
        f"ss -tlnp > '{backup_dir}/ss-tlnp.txt' 2>&1",
        f"iptables-save > '{backup_dir}/iptables-save.txt' 2>&1 || true",
        f"journalctl -u {args.legacy_unit} -n 400 --no-pager > '{backup_dir}/journal-{args.legacy_unit}.log' 2>&1 || true",
        "cp -a /usr/local/etc/xray '{backup}' 2>/dev/null || true".replace("{backup}", backup_dir),
        "cp -a /etc/systemd/system/xray* '{backup}' 2>/dev/null || true".replace("{backup}", backup_dir),
        "cp -a /lib/systemd/system/xray* '{backup}' 2>/dev/null || true".replace("{backup}", backup_dir),
        "cp -a /var/log/xray '{backup}' 2>/dev/null || true".replace("{backup}", backup_dir),
    ]
    for cmd in snapshots:
        print(cmd)
        if args.apply:
            run_remote(rm, ssh_cfg, cmd)

    print_step("Check v2 unit health gate")
    health_cmd = f"systemctl is-active {args.v2_unit}"
    print(health_cmd)
    v2_active = "unknown"
    if args.apply:
        health_res = run_remote(rm, ssh_cfg, health_cmd)
        v2_active = (health_res.get("stdout") or "").strip().lower()
        print(v2_active or "(empty)")

    if args.apply and not args.allow_stop_without_v2 and v2_active != "active":
        raise RuntimeError(
            f"Safety gate: {args.v2_unit} is not active. "
            "Use --allow-stop-without-v2 only for explicit maintenance."
        )

    print_step("Legacy cleanup plan")
    cleanup_commands = [
        f"systemctl stop {args.legacy_unit}",
        f"systemctl disable {args.legacy_unit} || true",
        f"systemctl mask {args.legacy_unit} || true",
        f"test -f '{args.legacy_config}' && mv '{args.legacy_config}' '{backup_dir}/legacy-config.json' || true",
        "systemctl daemon-reload",
        f"systemctl restart {args.v2_unit}",
        f"systemctl status {args.v2_unit} --no-pager | head -20",
    ]
    for cmd in cleanup_commands:
        print(cmd)
        if args.apply:
            res = run_remote(rm, ssh_cfg, cmd)
            out = (res.get("stdout") or "").strip()
            err = (res.get("stderr") or "").strip()
            if out:
                print(out)
            if err:
                print(err)

    print_step("Post-check")
    post_checks = [
        "ss -tlnp | grep -E 'xray|:443|:4443|:8443|:2053' || true",
        f"systemctl is-active {args.legacy_unit} || true",
        f"systemctl is-active {args.v2_unit} || true",
    ]
    for cmd in post_checks:
        print(cmd)
        if args.apply:
            res = run_remote(rm, ssh_cfg, cmd)
            print((res.get("stdout") or "").strip())

    print("\nDone.")
    print("Rollback: restore files from backup dir and unmask/enable/start legacy unit.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

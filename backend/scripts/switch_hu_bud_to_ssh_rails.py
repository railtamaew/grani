#!/usr/bin/env python3
"""
Emergency rollback: switch HU-BUD-01 from edge-agent rails to legacy SSH rails.

What it does:
1) Clears edge-agent token metadata in DB for selected server.
2) Stops/disables edge heartbeat/poll timers on remote node (best effort).
3) Verifies that Xray service is active on node.

Usage:
  PYTHONPATH=/opt/grani/backend:/opt/grani/backend/scripts \
    python3 backend/scripts/switch_hu_bud_to_ssh_rails.py --server-name HU-BUD-01
"""
from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime, timezone

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_BACKEND_ROOT = os.path.abspath(os.path.join(_SCRIPT_DIR, ".."))
if _BACKEND_ROOT not in sys.path:
    sys.path.insert(0, _BACKEND_ROOT)

import script_env  # noqa: E402

script_env.ensure_script_environment()

from core.database import SessionLocal  # noqa: E402
from models.server import Server  # noqa: E402
from services.remote_vpn_manager import RemoteVPNManager  # noqa: E402


def _run_remote(rm: RemoteVPNManager, cfg: dict, cmd: str) -> str:
    if not rm.ssh_manager:
        return "SSHManager unavailable"
    res = rm.ssh_manager.execute_command(
        cfg["host"],
        cmd,
        cfg["port"],
        cfg["username"],
        cfg.get("key_path"),
        cfg.get("key_content"),
        cfg.get("password"),
    )
    out = (res.get("stdout") or "") + (res.get("stderr") or "")
    return out.strip() or "(empty)"


def main() -> int:
    parser = argparse.ArgumentParser(description="Switch node to legacy SSH rails")
    parser.add_argument("--server-name", default="HU-BUD-01")
    parser.add_argument("--keep-edge-services", action="store_true")
    args = parser.parse_args()

    db = SessionLocal()
    try:
        server = db.query(Server).filter(Server.name == args.server_name).first()
        if not server:
            print(f"Server not found: {args.server_name}", file=sys.stderr)
            return 1

        prev_token = str(getattr(server, "edge_agent_token_hash", "") or "")
        prev_hb = getattr(server, "edge_last_heartbeat_at", None)
        prev_cfg = str(getattr(server, "edge_reported_config_hash", "") or "")
        print(f"[{datetime.now(timezone.utc).isoformat()}] switching server={server.name} id={server.id}")
        print(f"before: token_set={bool(prev_token)} heartbeat={prev_hb} reported_hash={prev_cfg[:24] if prev_cfg else '-'}")

        server.edge_agent_token_hash = None
        server.edge_last_heartbeat_at = None
        server.edge_reported_config_hash = None
        server.edge_agent_version = None
        db.add(server)
        db.commit()
        db.refresh(server)
        print("db: edge-agent fields cleared -> legacy SSH rails active for apply path")

        rm = RemoteVPNManager()
        cfg = rm.get_ssh_config(server)
        if not cfg:
            print("warning: ssh config unavailable, DB rollback already applied")
            return 0

        if not args.keep_edge_services:
            cmd_disable = (
                "set -euo pipefail; "
                "for u in grani-edge-heartbeat.timer grani-edge-heartbeat.service "
                "grani-edge-poll.timer grani-edge-poll.service; do "
                "systemctl disable --now \"$u\" >/dev/null 2>&1 || true; "
                "done; "
                "systemctl daemon-reload >/dev/null 2>&1 || true; "
                "echo edge_services_disabled"
            )
            print(_run_remote(rm, cfg, cmd_disable))

        cmd_verify = (
            "set -euo pipefail; "
            "echo -n 'xray-v2='; systemctl is-active xray-v2 2>/dev/null || true; "
            "echo -n 'xray='; systemctl is-active xray 2>/dev/null || true"
        )
        print(_run_remote(rm, cfg, cmd_verify))

        print("done: server switched to SSH rails")
        return 0
    finally:
        db.close()


if __name__ == "__main__":
    raise SystemExit(main())

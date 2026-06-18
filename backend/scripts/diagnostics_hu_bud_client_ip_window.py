#!/usr/bin/env python3
"""
Window diagnostics for a specific client IP on HU-BUD-01.

Collects:
- ss -tin snapshots for :4443 filtered by client IP
- conntrack counters for client IP
- TCP retrans counter delta from /proc/net/snmp
- xray error log tail for client IP and :4443

Read-only via RemoteVPNManager (SSH config from DB).
"""
from __future__ import annotations

import argparse
import os
import sys
import time
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


def _run_cmd(rm: RemoteVPNManager, cfg: dict, cmd: str) -> str:
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


def _tcp_retrans_segs(rm: RemoteVPNManager, cfg: dict) -> int:
    cmd = (
        "awk 'BEGIN{h=\"\"} /^Tcp:/{if(h==\"\"){h=$0}else{print $0; exit}}' /proc/net/snmp "
        "| awk '{for(i=1;i<=NF;i++){if(NR==1&&$i==\"RetransSegs\")idx=i; if(NR==2&&idx>0)print $idx}}'"
    )
    raw = _run_cmd(rm, cfg, cmd).strip().splitlines()
    for line in reversed(raw):
        line = line.strip()
        if line.isdigit():
            return int(line)
    return -1


def main() -> int:
    parser = argparse.ArgumentParser(description="Client-IP window diagnostics on HU-BUD-01")
    parser.add_argument("--server-name", default="HU-BUD-01")
    parser.add_argument("--client-ip", required=True, help="Client public IP for correlation")
    parser.add_argument("--window-sec", type=int, default=90)
    parser.add_argument("--interval-sec", type=int, default=5)
    args = parser.parse_args()

    db = SessionLocal()
    try:
        server = db.query(Server).filter(Server.name == args.server_name).first()
        if not server:
            print(f"Server not found: {args.server_name}", file=sys.stderr)
            return 1
        rm = RemoteVPNManager()
        cfg = rm.get_ssh_config(server)
        if not cfg:
            print("SSH config missing", file=sys.stderr)
            return 1

        window = max(10, args.window_sec)
        step = max(2, args.interval_sec)
        samples = max(1, window // step)
        client_ip = args.client_ip.strip()

        print(f"# Node diagnostics server={args.server_name} ip={client_ip}")
        print(f"# window_sec={window} interval_sec={step} samples={samples}")
        print(f"# started_at={datetime.now(timezone.utc).isoformat()}")

        retrans_before = _tcp_retrans_segs(rm, cfg)
        conntrack_before = _run_cmd(
            rm,
            cfg,
            f"conntrack -S 2>/dev/null | sed 's/^/conntrack: /' || "
            f"grep -c '{client_ip}' /proc/net/nf_conntrack 2>/dev/null | awk '{{print \"conntrack_count: \"$1}}'",
        )
        print(f"\n[before] tcp_retrans_segs={retrans_before}")
        print(conntrack_before)

        for i in range(samples):
            ts = datetime.now(timezone.utc).isoformat()
            print(f"\n[sample {i + 1}/{samples}] ts={ts}")
            ss_cmd = (
                "ss -tin sport = :4443 2>/dev/null "
                f"| awk 'BEGIN{{show=0}} /{client_ip}/{{show=1; print; next}} "
                "show==1{print; if($0 ~ /^$/){show=0}}' | sed 's/^/ss: /'"
            )
            print(_run_cmd(rm, cfg, ss_cmd))
            print(
                _run_cmd(
                    rm,
                    cfg,
                    f"conntrack -L 2>/dev/null | grep '{client_ip}' | wc -l "
                    "| awk '{print \"conntrack_entries: \"$1}'",
                )
            )
            time.sleep(step)

        retrans_after = _tcp_retrans_segs(rm, cfg)
        conntrack_after = _run_cmd(
            rm,
            cfg,
            f"conntrack -S 2>/dev/null | sed 's/^/conntrack: /' || "
            f"grep -c '{client_ip}' /proc/net/nf_conntrack 2>/dev/null | awk '{{print \"conntrack_count: \"$1}}'",
        )
        print(f"\n[after] tcp_retrans_segs={retrans_after}")
        if retrans_before >= 0 and retrans_after >= 0:
            print(f"[delta] tcp_retrans_segs={retrans_after - retrans_before}")
        print(conntrack_after)
        print(
            _run_cmd(
                rm,
                cfg,
                f"tail -n 80 /var/log/xray/error.log 2>/dev/null | grep -E '{client_ip}|:4443' || true",
            )
        )
        print(f"# finished_at={datetime.now(timezone.utc).isoformat()}")
        return 0
    finally:
        db.close()


if __name__ == "__main__":
    raise SystemExit(main())

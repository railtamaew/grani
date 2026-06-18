#!/usr/bin/env python3
"""
Apply nftables churn guard on HU-BUD-01 via RemoteVPNManager SSH config.

What it does:
1) Uploads a deterministic nftables guard script to /root.
2) Executes it on node.
3) Prints resulting chain state for verification.
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


NFT_SCRIPT = r"""#!/usr/bin/env bash
set -euo pipefail
if ! command -v nft >/dev/null 2>&1; then
  echo "nft command not found"
  exit 1
fi
TABLE_FAMILY="inet"
TABLE_NAME="grani_xray_guard"
CHAIN_NAME="syn_guard"
nft list table "${TABLE_FAMILY}" "${TABLE_NAME}" >/dev/null 2>&1 || nft add table "${TABLE_FAMILY}" "${TABLE_NAME}"
nft list chain "${TABLE_FAMILY}" "${TABLE_NAME}" "${CHAIN_NAME}" >/dev/null 2>&1 || \
  nft add chain "${TABLE_FAMILY}" "${TABLE_NAME}" "${CHAIN_NAME}" "{ type filter hook input priority 0; policy accept; }"
nft flush chain "${TABLE_FAMILY}" "${TABLE_NAME}" "${CHAIN_NAME}"
nft add rule "${TABLE_FAMILY}" "${TABLE_NAME}" "${CHAIN_NAME}" \
  tcp dport 4443 tcp flags syn / syn limit rate over 25/second burst 50 packets drop
nft add rule "${TABLE_FAMILY}" "${TABLE_NAME}" "${CHAIN_NAME}" \
  tcp dport { 2053, 8443, 4443 } tcp flags syn / syn limit rate over 80/second burst 160 packets drop
echo "Applied nft guard in ${TABLE_FAMILY}/${TABLE_NAME}/${CHAIN_NAME}"
nft list chain "${TABLE_FAMILY}" "${TABLE_NAME}" "${CHAIN_NAME}"
"""


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
    parser = argparse.ArgumentParser(description="Apply nft guard on HU-BUD-01")
    parser.add_argument("--server-name", default="HU-BUD-01")
    parser.add_argument("--remote-path", default="/root/apply-xray-v2-nft-guard.sh")
    args = parser.parse_args()

    db = SessionLocal()
    try:
        server = db.query(Server).filter(Server.name == args.server_name).first()
        if not server:
            print(f"Server not found: {args.server_name!r}", file=sys.stderr)
            return 1

        rm = RemoteVPNManager()
        cfg = rm.get_ssh_config(server)
        if not cfg:
            print("SSH config missing", file=sys.stderr)
            return 1

        print(f"[{datetime.now(timezone.utc).isoformat()}] apply nft guard server={server.name}")
        detect_cmd = (
            "set -euo pipefail; "
            "echo -n 'nft='; command -v nft || true; "
            "echo -n ' firewall-cmd='; command -v firewall-cmd || true; "
            "echo -n ' ufw='; command -v ufw || true; "
            "echo -n ' iptables='; command -v iptables || true"
        )
        print(_run_remote(rm, cfg, detect_cmd))

        script_escaped = NFT_SCRIPT.replace("'", "'\"'\"'")
        upload_cmd = (
            "set -euo pipefail; "
            f"printf '%s' '{script_escaped}' > '{args.remote_path}'; "
            f"chmod +x '{args.remote_path}'; "
            f"echo uploaded:{args.remote_path}"
        )
        print(_run_remote(rm, cfg, upload_cmd))

        run_cmd = f"set -euo pipefail; '{args.remote_path}'"
        run_out = _run_remote(rm, cfg, run_cmd)
        print(run_out)
        if "nft command not found" in run_out:
            fallback_cmd = (
                "set -euo pipefail; "
                "echo 'nft missing on node; firewalld runtime status:'; "
                "systemctl is-active firewalld 2>/dev/null || true; "
                "echo 'firewalld direct rules:'; "
                "firewall-cmd --direct --get-all-rules 2>/dev/null || true"
            )
            print(_run_remote(rm, cfg, fallback_cmd))
            ipt_cmd = (
                "set -euo pipefail; "
                "CHAIN_BASELINE='XRAYV2_GUARD'; "
                "CHAIN_4443='XRAYV2_4443_CHURN_GUARD'; "
                "iptables -nL \"$CHAIN_BASELINE\" >/dev/null 2>&1 || iptables -N \"$CHAIN_BASELINE\"; "
                "iptables -nL \"$CHAIN_4443\" >/dev/null 2>&1 || iptables -N \"$CHAIN_4443\"; "
                "iptables -F \"$CHAIN_BASELINE\"; "
                "iptables -F \"$CHAIN_4443\"; "
                "iptables -A \"$CHAIN_BASELINE\" -m limit --limit 80/second --limit-burst 160 -j RETURN; "
                "iptables -A \"$CHAIN_BASELINE\" -j DROP; "
                "iptables -A \"$CHAIN_4443\" -m limit --limit 15/second --limit-burst 30 -j RETURN; "
                "iptables -A \"$CHAIN_4443\" -j DROP; "
                "for p in 2053 8443 4443; do "
                "while iptables -C INPUT -p tcp --syn --dport \"$p\" -j \"$CHAIN_BASELINE\" >/dev/null 2>&1; do "
                "iptables -D INPUT -p tcp --syn --dport \"$p\" -j \"$CHAIN_BASELINE\"; "
                "done; "
                "iptables -I INPUT -p tcp --syn --dport \"$p\" -j \"$CHAIN_BASELINE\"; "
                "done; "
                "while iptables -C INPUT -p tcp --syn --dport 4443 -j \"$CHAIN_4443\" >/dev/null 2>&1; do "
                "iptables -D INPUT -p tcp --syn --dport 4443 -j \"$CHAIN_4443\"; "
                "done; "
                "iptables -I INPUT -p tcp --syn --dport 4443 -j \"$CHAIN_4443\"; "
                "echo 'Applied iptables fallback guard (4443=15/s burst=30)'; "
                "iptables -S \"$CHAIN_BASELINE\"; "
                "iptables -S \"$CHAIN_4443\""
            )
            print(_run_remote(rm, cfg, ipt_cmd))
        return 0
    finally:
        db.close()


if __name__ == "__main__":
    raise SystemExit(main())

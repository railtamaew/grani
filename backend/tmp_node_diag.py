from types import SimpleNamespace

from sqlalchemy import text

from core.database import SessionLocal
from infrastructure.external.remote_vpn_manager import RemoteVPNManager


REMOTE_CMD = r"""
set -o pipefail 2>/dev/null || true
echo "### host"
hostname
date -Is
echo "### os"
uname -a
grep -E 'PRETTY_NAME|VERSION=' /etc/os-release 2>/dev/null || true
echo "### addresses"
ip -4 addr show
echo "### routes"
ip route
echo "### sysctl"
sysctl net.ipv4.ip_forward net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter 2>/dev/null || true
echo "### wg"
(awg show wg0 || wg show wg0 || true) 2>&1
echo "### links"
ip -s link show wg0 2>/dev/null || true
default_if=$(ip route show default | awk '{print $5; exit}')
if [ -n "$default_if" ]; then ip -s link show "$default_if" 2>/dev/null || true; fi
echo "### listeners"
ss -lunp | grep -E '(:51820|:39060|amnezia|wg)' || true
echo "### nft"
nft list ruleset 2>/dev/null | sed -n '1,260p' || true
echo "### iptables"
iptables-save 2>/dev/null | grep -E 'POSTROUTING|FORWARD|MASQUERADE|10\.0\.0\.0|wg0|51820|39060' || true
echo "### wg0.conf"
sed -n '1,240p' /etc/amnezia/amneziawg/wg0.conf 2>/dev/null | sed -E 's/(PrivateKey = ).+/\1***MASKED***/'
"""


def run() -> None:
    db = SessionLocal()
    manager = RemoteVPNManager()
    try:
        for server_id in (5, 7):
            row = db.execute(text("select * from servers where id = :id"), {"id": server_id}).mappings().first()
            server = SimpleNamespace(**dict(row)) if row else None
            if not server:
                print(f"===== server {server_id}: missing =====")
                continue
            cfg = manager.get_ssh_config(server)
            print(f"===== server {server.id} {server.name} {server.ip_address}:{server.wireguard_port} =====")
            result = manager.ssh_manager.execute_command(
                cfg["host"],
                REMOTE_CMD,
                cfg["port"],
                cfg["username"],
                key_path=cfg.get("key_path"),
                key_content=cfg.get("key_content"),
                password=cfg.get("password"),
            )
            print(f"success={result.get('success')} exit={result.get('exit_status')}")
            if result.get("stdout"):
                print(result["stdout"])
            if result.get("stderr"):
                print("### stderr")
                print(result["stderr"])
    finally:
        db.close()


if __name__ == "__main__":
    run()

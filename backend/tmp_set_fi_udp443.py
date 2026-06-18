from types import SimpleNamespace

from sqlalchemy import text

from core.database import SessionLocal
from infrastructure.external.remote_vpn_manager import RemoteVPNManager


REMOTE_CMD = r"""
set -e
conf=/etc/amnezia/amneziawg/wg0.conf
backup=/etc/amnezia/amneziawg/wg0.conf.bak-20260609-udp443-test
cp -a "$conf" "$backup"
sed -i 's/^ListenPort = .*/ListenPort = 443/' "$conf"
awg set wg0 listen-port 443
echo "### listener"
ss -lunp | grep -E '(:443|:51820)' || true
echo "### awg"
awg show wg0 | sed -n '1,34p'
echo "### config"
grep -E '^(ListenPort|MTU|Address|Jc|Jmin|Jmax|H[1-4])' "$conf" || true
"""


def run() -> None:
    db = SessionLocal()
    manager = RemoteVPNManager()
    try:
        row = db.execute(text("select * from servers where id = 7")).mappings().first()
        if not row:
            raise RuntimeError("Server id=7 not found")
        server = SimpleNamespace(**dict(row))
        cfg = manager.get_ssh_config(server)
        result = manager.ssh_manager.execute_command(
            cfg["host"],
            REMOTE_CMD,
            cfg["port"],
            cfg["username"],
            key_path=cfg.get("key_path"),
            key_content=cfg.get("key_content"),
            password=cfg.get("password"),
        )
        print(result.get("stdout", ""))
        if result.get("stderr"):
            print("### stderr")
            print(result["stderr"])
        if not result.get("success"):
            raise RuntimeError(f"Remote port switch failed: {result}")
        db.execute(text("""
            update servers
            set wireguard_port = 443,
                server_specs = coalesce(server_specs, '{}'::jsonb)
                    || jsonb_build_object(
                        'udp_port_test', '443-lte-hetzner-20260609',
                        'previous_wireguard_port', '51820'
                    ),
                updated_at = now()
            where id = 7
        """))
        db.commit()
        print("DB updated: server 7 wireguard_port=443")
    finally:
        db.close()


if __name__ == "__main__":
    run()

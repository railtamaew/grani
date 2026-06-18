from types import SimpleNamespace

from sqlalchemy import text

from core.database import SessionLocal
from services.remote_vpn_manager import RemoteVPNManager


def main() -> None:
    session = SessionLocal()
    try:
        user_row = session.execute(
            text("SELECT id, email FROM users WHERE id = 1 LIMIT 1")
        ).fetchone()
        print("user_email", user_row.email if user_row else None)

        device_row = session.execute(
            text(
                "SELECT * "
                "FROM devices WHERE device_id = :device_id LIMIT 1"
            ),
            {"device_id": "a60d1dcd-c070-4579-a0d0-623200965e64"},
        ).mappings().first()
        print("device_found", bool(device_row))
        if device_row:
            print("device_columns", sorted(list(device_row.keys())))
            print("device_id", device_row.get("id"))
            print("device_vpn_client_id", device_row.get("vpn_client_id"))
            print("device_is_active", device_row.get("is_active"))

        server_row = session.execute(
            text("SELECT * FROM servers WHERE name = 'HU-BUD-01' LIMIT 1")
        ).mappings().first()
        if not server_row:
            print("server_not_found")
            return
        server = SimpleNamespace(**dict(server_row))
        rm = RemoteVPNManager()
        cfg = rm.get_ssh_config(server)
        sm = rm.ssh_manager
        if not sm:
            print("ssh_manager_missing")
            return

        commands = [
            "date -u; date",
            "systemctl is-active xray-v2; systemctl is-active xray; /usr/local/bin/xray version 2>/dev/null || xray version 2>/dev/null || true",
            "ss -tlnp | awk 'NR==1 || /:443 |:4443 |:8443 |:2053 /'",
            "sed -n '1,260p' /usr/local/etc/xray/config-v2.json",
            "python3 - <<'P'\nfrom pathlib import Path\np=Path('/var/log/xray/access.log')\nif not p.exists():\n print('no_access_log'); raise SystemExit\nfor ln in p.read_text(encoding='utf-8',errors='ignore').splitlines():\n if '2026/05/06 15:0' in ln:\n  print(ln)\nP",
            "python3 - <<'P'\nfrom pathlib import Path\np=Path('/var/log/xray/error.log')\nif not p.exists():\n print('no_error_log'); raise SystemExit\nfor ln in p.read_text(encoding='utf-8',errors='ignore').splitlines():\n if '2026/05/06 15:0' in ln:\n  print(ln)\nP",
            "iptables -L INPUT -n",
        ]

        for cmd in commands:
            result = sm.execute_command(
                cfg["host"],
                cmd,
                cfg["port"],
                cfg["username"],
                cfg.get("key_path"),
                cfg.get("key_content"),
                cfg.get("password"),
            )
            print("\n=== CMD ===")
            print(cmd)
            print("exit", result.get("exit_status"))
            out = result.get("stdout") or ""
            err = result.get("stderr") or ""
            if out:
                print(out[:12000])
            if err:
                print("ERR:", err[:2000])
    finally:
        session.close()


if __name__ == "__main__":
    main()

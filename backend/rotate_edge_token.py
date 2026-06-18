import hashlib
import secrets

from core.database import SessionLocal
from models.server import Server
from services.remote_vpn_manager import RemoteVPNManager


def run() -> None:
    session = SessionLocal()
    try:
        server = session.query(Server).filter(Server.name == "HU-BUD-01").first()
        if server is None:
            raise RuntimeError("server HU-BUD-01 not found")

        token = secrets.token_urlsafe(32)
        token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
        server.edge_agent_token_hash = token_hash
        session.commit()
        print("db_token_hash_updated=yes")

        rm = RemoteVPNManager()
        sm = rm.ssh_manager
        if sm is None:
            raise RuntimeError("ssh manager unavailable")
        cfg = rm.get_ssh_config(server)

        mk = sm.execute_command(
            cfg["host"],
            "mkdir -p /etc/grani-edge",
            cfg["port"],
            cfg["username"],
            cfg.get("key_path"),
            cfg.get("key_content"),
            cfg.get("password"),
        )
        if mk.get("exit_status") != 0:
            raise RuntimeError("failed to ensure /etc/grani-edge directory")

        ok = sm.upload_content_atomic(
            cfg["host"],
            token + "\n",
            "/etc/grani-edge/token",
            cfg["port"],
            cfg["username"],
            cfg.get("key_path"),
            cfg.get("key_content"),
            cfg.get("password"),
        )
        if not ok:
            raise RuntimeError("failed to upload /etc/grani-edge/token")

        for cmd in [
            "chmod 600 /etc/grani-edge/token",
            "chown root:root /etc/grani-edge/token",
            "systemctl start grani-edge-heartbeat.service",
            "systemctl status --no-pager grani-edge-heartbeat.service",
            "journalctl -u grani-edge-heartbeat.service -n 10 --no-pager",
        ]:
            res = sm.execute_command(
                cfg["host"],
                cmd,
                cfg["port"],
                cfg["username"],
                cfg.get("key_path"),
                cfg.get("key_content"),
                cfg.get("password"),
            )
            print(f"cmd: {cmd}")
            print(f"exit: {res.get('exit_status')}")
            out = (res.get("stdout") or "").strip()
            err = (res.get("stderr") or "").strip()
            if out:
                print(out)
            if err:
                print(f"err: {err}")
    finally:
        session.close()


if __name__ == "__main__":
    run()

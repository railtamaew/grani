from pathlib import Path

from core.database import SessionLocal
from models.server import Server
from services.remote_vpn_manager import RemoteVPNManager


def up(sm, cfg, local_path: str, remote_path: str) -> None:
    content = Path(local_path).read_text(encoding="utf-8")
    ok = sm.upload_content_atomic(
        cfg["host"],
        content,
        remote_path,
        cfg["port"],
        cfg["username"],
        cfg.get("key_path"),
        cfg.get("key_content"),
        cfg.get("password"),
    )
    if not ok:
        raise RuntimeError(f"upload failed: {remote_path}")
    print(f"uploaded: {remote_path}")


def run() -> None:
    session = SessionLocal()
    try:
        server = session.query(Server).filter(Server.name == "HU-BUD-01").first()
        if server is None:
            raise RuntimeError("server HU-BUD-01 not found")

        rm = RemoteVPNManager()
        sm = rm.ssh_manager
        if sm is None:
            raise RuntimeError("ssh manager unavailable")

        cfg = rm.get_ssh_config(server)
        base = "/app/scripts/edge-node"
        uploads = [
            (f"{base}/heartbeat.sh", "/usr/local/bin/grani-edge-heartbeat"),
            (f"{base}/poll-and-apply.sh", "/usr/local/bin/grani-edge-poll"),
            (
                f"{base}/grani-edge-heartbeat.service.example",
                "/etc/systemd/system/grani-edge-heartbeat.service",
            ),
            (
                f"{base}/grani-edge-heartbeat.timer.example",
                "/etc/systemd/system/grani-edge-heartbeat.timer",
            ),
            (
                f"{base}/grani-edge-poll.service.example",
                "/etc/systemd/system/grani-edge-poll.service",
            ),
            (
                f"{base}/grani-edge-poll.timer.example",
                "/etc/systemd/system/grani-edge-poll.timer",
            ),
        ]
        for local_path, remote_path in uploads:
            up(sm, cfg, local_path, remote_path)

        env_cmd = (
            "touch /etc/default/grani-edge && "
            "grep -q '^GRANI_XRAY_SYSTEMD_UNIT=' /etc/default/grani-edge && "
            "sed -i 's/^GRANI_XRAY_SYSTEMD_UNIT=.*/GRANI_XRAY_SYSTEMD_UNIT=xray-v2/' /etc/default/grani-edge || "
            "echo 'GRANI_XRAY_SYSTEMD_UNIT=xray-v2' >> /etc/default/grani-edge; "
            "grep -q '^GRANI_EDGE_STATE_DIR=' /etc/default/grani-edge && "
            "sed -i 's|^GRANI_EDGE_STATE_DIR=.*|GRANI_EDGE_STATE_DIR=/var/lib/grani-edge|' /etc/default/grani-edge || "
            "echo 'GRANI_EDGE_STATE_DIR=/var/lib/grani-edge' >> /etc/default/grani-edge; "
            "grep -q '^GRANI_HEARTBEAT_MIN_INTERVAL_OK_SEC=' /etc/default/grani-edge && "
            "sed -i 's/^GRANI_HEARTBEAT_MIN_INTERVAL_OK_SEC=.*/GRANI_HEARTBEAT_MIN_INTERVAL_OK_SEC=120/' /etc/default/grani-edge || "
            "echo 'GRANI_HEARTBEAT_MIN_INTERVAL_OK_SEC=120' >> /etc/default/grani-edge; "
            "grep -q '^GRANI_HEARTBEAT_MIN_INTERVAL_FAIL_SEC=' /etc/default/grani-edge && "
            "sed -i 's/^GRANI_HEARTBEAT_MIN_INTERVAL_FAIL_SEC=.*/GRANI_HEARTBEAT_MIN_INTERVAL_FAIL_SEC=30/' /etc/default/grani-edge || "
            "echo 'GRANI_HEARTBEAT_MIN_INTERVAL_FAIL_SEC=30' >> /etc/default/grani-edge; "
            "grep -q '^GRANI_ASSIGNMENT_POLL_MIN_EMPTY_SEC=' /etc/default/grani-edge && "
            "sed -i 's/^GRANI_ASSIGNMENT_POLL_MIN_EMPTY_SEC=.*/GRANI_ASSIGNMENT_POLL_MIN_EMPTY_SEC=180/' /etc/default/grani-edge || "
            "echo 'GRANI_ASSIGNMENT_POLL_MIN_EMPTY_SEC=180' >> /etc/default/grani-edge; "
            "grep -q '^GRANI_ASSIGNMENT_POLL_MIN_WORK_SEC=' /etc/default/grani-edge && "
            "sed -i 's/^GRANI_ASSIGNMENT_POLL_MIN_WORK_SEC=.*/GRANI_ASSIGNMENT_POLL_MIN_WORK_SEC=30/' /etc/default/grani-edge || "
            "echo 'GRANI_ASSIGNMENT_POLL_MIN_WORK_SEC=30' >> /etc/default/grani-edge"
        )

        commands = [
            "chmod +x /usr/local/bin/grani-edge-heartbeat /usr/local/bin/grani-edge-poll",
            "mkdir -p /var/lib/grani-edge",
            env_cmd,
            "systemctl daemon-reload",
            "systemctl enable --now grani-edge-heartbeat.timer grani-edge-poll.timer",
            "systemctl restart grani-edge-heartbeat.timer grani-edge-poll.timer",
            "systemctl start grani-edge-heartbeat.service grani-edge-poll.service",
            "grep -E 'GRANI_(XRAY_SYSTEMD_UNIT|HEARTBEAT_MIN_INTERVAL_OK_SEC|ASSIGNMENT_POLL_MIN_EMPTY_SEC)' /etc/default/grani-edge || true",
            "systemctl is-active grani-edge-heartbeat.timer grani-edge-poll.timer",
            "systemctl list-timers --all | grep -E 'grani-edge-(heartbeat|poll)' || true",
        ]
        for cmd in commands:
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

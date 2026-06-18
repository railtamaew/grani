from core.database import SessionLocal
from models.server import Server
from services.remote_vpn_manager import RemoteVPNManager


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

        commands = [
            "set -a; . /etc/default/grani-edge 2>/dev/null || true; "
            "echo API_BASE=${GRANI_API_BASE:-missing}; "
            "echo NODE_ID=${GRANI_NODE_ID:-missing}; "
            "echo TOKEN_FILE=${GRANI_NODE_TOKEN_FILE:-/etc/grani-edge/token}; "
            "test -r ${GRANI_NODE_TOKEN_FILE:-/etc/grani-edge/token} && echo TOKEN_READABLE=yes || echo TOKEN_READABLE=no",
            "set -a; . /etc/default/grani-edge 2>/dev/null || true; "
            "TOKEN_FILE=${GRANI_NODE_TOKEN_FILE:-/etc/grani-edge/token}; "
            "if [ -r \"$TOKEN_FILE\" ]; then "
            "RAW=$(tr -d '\\n\\r' < \"$TOKEN_FILE\"); "
            "echo TOKEN_LEN=${#RAW}; "
            "printf '%s' \"$RAW\" | sha256sum | awk '{print \"TOKEN_SHA256=\"$1}'; "
            "else echo TOKEN_LEN=0; fi",
            "command -v jq >/dev/null && echo JQ_OK=yes || echo JQ_OK=no",
            "set -a; . /etc/default/grani-edge 2>/dev/null || true; "
            "TOKEN_FILE=${GRANI_NODE_TOKEN_FILE:-/etc/grani-edge/token}; "
            "TOKEN=$(tr -d '\\n\\r' < \"$TOKEN_FILE\" 2>/dev/null || true); "
            "curl -sS -o /tmp/grani_hb_test.txt -w '%{http_code}' "
            "-X POST 'https://api.granilink.com/api/internal/node/v1/heartbeat' "
            "-H 'Content-Type: application/json' "
            "-H \"Authorization: Bearer ${TOKEN}\" "
            "-d '{\"node_id\":1,\"config_hash\":\"sha256:test\",\"xray_running\":true,\"agent_version\":\"1\"}'; "
            "echo; cat /tmp/grani_hb_test.txt 2>/dev/null || true",
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
            print("CMD:", cmd)
            print("EXIT:", res.get("exit_status"))
            if res.get("stdout"):
                print(res["stdout"].strip())
            if res.get("stderr"):
                print("ERR:", res["stderr"].strip())
    finally:
        session.close()


if __name__ == "__main__":
    run()

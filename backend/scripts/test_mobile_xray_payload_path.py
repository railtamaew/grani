#!/usr/bin/env python3
"""
One-shot data-plane test with mobile-issued Xray config.

Flow:
1) Auth to API (token or email+code).
2) Create Xray client via backend API and fetch json_config (same payload mobile gets).
3) Launch temporary local Xray-core (Docker) with that config.
4) Send test traffic through local SOCKS5 inbound.
5) Collect HU-BUD-01 logs in exact server-time window.
6) Print verdict based on "accepted ... email: ..." vs timeout patterns.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Optional

import requests

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_BACKEND_ROOT = os.path.abspath(os.path.join(_SCRIPT_DIR, ".."))
if _BACKEND_ROOT not in sys.path:
    sys.path.insert(0, _BACKEND_ROOT)

from scripts import script_env  # noqa: E402

script_env.ensure_script_environment()

from core.database import SessionLocal  # noqa: E402
from models.server import Server  # noqa: E402
from models.user import Device  # noqa: E402
from services.remote_vpn_manager import RemoteVPNManager  # noqa: E402


@dataclass
class ApiContext:
    token: str
    user_id: int


def _log(msg: str) -> None:
    print(msg, flush=True)


def _request_json(method: str, url: str, **kwargs: Any) -> Dict[str, Any]:
    r = requests.request(method, url, timeout=kwargs.pop("timeout", 25), **kwargs)
    body = r.text.strip()
    if r.status_code >= 400:
        raise RuntimeError(f"{method} {url} failed: {r.status_code} {body[:800]}")
    try:
        return r.json()
    except Exception as exc:
        raise RuntimeError(f"Non-JSON response from {url}: {body[:400]}") from exc


def _auth(base_url: str, email: str, code: Optional[str], token: Optional[str]) -> ApiContext:
    if token:
        me = _request_json(
            "GET",
            f"{base_url}/api/auth/me",
            headers={"Authorization": f"Bearer {token}"},
            timeout=15,
        )
        user = me.get("user") or {}
        user_id = int(user.get("id") or 0)
        if user_id <= 0:
            raise RuntimeError("Unable to resolve user id from /api/auth/me")
        return ApiContext(token=token, user_id=user_id)

    if not code:
        raise RuntimeError("Provide --code (or --token).")

    auth = _request_json(
        "POST",
        f"{base_url}/api/auth/verify-code",
        json={"email": email, "code": code},
        timeout=20,
    )
    access_token = str(auth.get("access_token") or "")
    if not access_token:
        raise RuntimeError("verify-code did not return access_token")
    me = _request_json(
        "GET",
        f"{base_url}/api/auth/me",
        headers={"Authorization": f"Bearer {access_token}"},
        timeout=15,
    )
    user = me.get("user") or {}
    user_id = int(user.get("id") or 0)
    if user_id <= 0:
        raise RuntimeError("Unable to resolve user id from /api/auth/me after verify-code")
    return ApiContext(token=access_token, user_id=user_id)


def _get_or_create_device_db_id(user_id: int, device_id: str) -> int:
    db = SessionLocal()
    try:
        row = (
            db.query(Device)
            .filter(Device.user_id == user_id, Device.device_id == device_id)
            .order_by(Device.id.desc())
            .first()
        )
        if not row:
            raise RuntimeError(
                "Device row not found in DB after create-client. "
                "Run once with same --device-id via mobile or API create-client."
            )
        return int(row.id)
    finally:
        db.close()


def _create_client(
    base_url: str,
    token: str,
    server_id: int,
    device_id: str,
    protocol: str,
) -> Dict[str, Any]:
    return _request_json(
        "POST",
        f"{base_url}/api/vpn/xray/create-client",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json={"server_id": server_id, "device_id": device_id, "protocol": protocol},
        timeout=35,
    )


def _build_xray_runtime_config(json_cfg: Dict[str, Any], protocol_api: str) -> Dict[str, Any]:
    protocol = str(json_cfg.get("protocol") or "").strip().lower()
    if not protocol:
        protocol = "vmess" if protocol_api == "xray_vmess" else "vless"
    address = str(json_cfg.get("add") or "")
    port = int(json_cfg.get("port"))
    user_id = str(json_cfg.get("id") or "")
    network = str(json_cfg.get("net") or "tcp")
    tls = str(json_cfg.get("tls") or "none")
    host = str(json_cfg.get("host") or "")
    path = str(json_cfg.get("path") or "")
    sni = str(json_cfg.get("sni") or "")

    outbound: Dict[str, Any] = {
        "tag": "proxy",
        "protocol": protocol,
        "settings": {
            "vnext": [
                {
                    "address": address,
                    "port": port,
                    "users": [
                        {"id": user_id, "encryption": "none"}
                        if protocol == "vless"
                        else {
                            "id": user_id,
                            "alterId": int(json_cfg.get("aid") or 0),
                            "security": str(json_cfg.get("scy") or "none"),
                        }
                    ],
                }
            ]
        },
    }

    stream: Dict[str, Any] = {"network": network}
    if tls == "reality":
        stream["security"] = "reality"
        stream["realitySettings"] = {
            "serverName": sni or "google.com",
            "publicKey": str(json_cfg.get("pbk") or ""),
            "shortId": str(json_cfg.get("sid") or ""),
            "fingerprint": str(json_cfg.get("fp") or "chrome"),
        }
    elif tls == "tls":
        stream["security"] = "tls"
        stream["tlsSettings"] = {"serverName": sni or host or address, "allowInsecure": False}

    if network == "ws":
        stream["wsSettings"] = {"path": path or "/", "headers": {"Host": host or sni or address}}
    elif network == "grpc":
        service_name = str(json_cfg.get("serviceName") or path or "xray-grpc")
        stream["grpcSettings"] = {"serviceName": service_name}

    outbound["streamSettings"] = stream
    config = {
        "log": {"loglevel": "warning"},
        "inbounds": [
            {
                "tag": "socks-in",
                "listen": "0.0.0.0",
                "port": 10808,
                "protocol": "socks",
                "settings": {"udp": True},
            }
        ],
        "outbounds": [
            outbound,
            {"tag": "direct", "protocol": "freedom", "settings": {}},
        ],
    }
    return config


def _run(cmd: list[str], *, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, text=True, capture_output=True, check=check)


def _docker_start_xray(config_path: Path, name: str) -> None:
    _run(["docker", "rm", "-f", name], check=False)
    cp = _run(
        [
            "docker",
            "run",
            "-d",
            "--rm",
            "--name",
            name,
            "-p",
            "127.0.0.1:10808:10808",
            "-v",
            f"{str(config_path)}:/etc/xray/config.json:ro",
            "teddysun/xray:latest",
        ]
    )
    cid = cp.stdout.strip()
    if not cid:
        raise RuntimeError(f"Unable to start xray container: {cp.stderr}")
    time.sleep(1.0)
    logs = _run(["docker", "logs", name], check=False)
    if "failed" in (logs.stdout + logs.stderr).lower():
        raise RuntimeError(f"xray container start failed:\n{logs.stdout}\n{logs.stderr}")


def _probe_via_socks(url: str) -> tuple[bool, str]:
    cmd = [
        "curl",
        "--socks5-hostname",
        "127.0.0.1:10808",
        "-m",
        "15",
        "-sS",
        "-o",
        "/dev/null",
        "-w",
        "%{http_code} %{time_total}",
        url,
    ]
    cp = _run(cmd, check=False)
    out = (cp.stdout or "").strip()
    ok = cp.returncode == 0 and out[:3].isdigit() and out[:3] != "000"
    return ok, (out or cp.stderr.strip())


def _remote_exec(rm: RemoteVPNManager, cfg: Dict[str, Any], cmd: str) -> str:
    if not rm.ssh_manager:
        raise RuntimeError("SSH manager unavailable")
    r = rm.ssh_manager.execute_command(
        cfg["host"],
        cmd,
        cfg["port"],
        cfg["username"],
        cfg.get("key_path"),
        cfg.get("key_content"),
        cfg.get("password"),
    )
    return ((r.get("stdout") or "") + (r.get("stderr") or "")).strip()


def _collect_server_window_logs(server_name: str, start_local: str, end_local: str, client_email: str) -> Dict[str, str]:
    db = SessionLocal()
    try:
        server = db.query(Server).filter(Server.name == server_name).first()
        if not server:
            raise RuntimeError(f"Server {server_name!r} not found in DB")
        rm = RemoteVPNManager()
        cfg = rm.get_ssh_config(server)
        if not cfg:
            raise RuntimeError("Unable to resolve SSH config from DB")
        marker = client_email.replace("'", "")
        access_cmd = (
            f"awk '$0 >= \"{start_local}\" && $0 <= \"{end_local}\"' /var/log/xray/access.log 2>/dev/null "
            f"| grep -E '{marker}|accepted|rejected|timeout' || true"
        )
        error_cmd = (
            f"awk '$0 >= \"{start_local}\" && $0 <= \"{end_local}\"' /var/log/xray/error.log 2>/dev/null "
            f"| grep -E '{marker}|i/o timeout|failed|rejected|accepted|4443|8443|2053|:443->' || true"
        )
        journal_cmd = (
            f"journalctl -u xray-v2 --since '{start_local.replace('/', '-')}' "
            f"--until '{end_local.replace('/', '-')}' --no-pager 2>/dev/null "
            "| grep -E 'accepted|rejected|timeout|failed' || true"
        )
        return {
            "access": _remote_exec(rm, cfg, access_cmd),
            "error": _remote_exec(rm, cfg, error_cmd),
            "journal": _remote_exec(rm, cfg, journal_cmd),
        }
    finally:
        db.close()


def _server_now_local(server_name: str) -> str:
    db = SessionLocal()
    try:
        server = db.query(Server).filter(Server.name == server_name).first()
        if not server:
            raise RuntimeError(f"Server {server_name!r} not found in DB")
        rm = RemoteVPNManager()
        cfg = rm.get_ssh_config(server)
        if not cfg:
            raise RuntimeError("Unable to resolve SSH config from DB")
        return _remote_exec(rm, cfg, "date '+%Y/%m/%d %H:%M:%S'")
    finally:
        db.close()


def main() -> int:
    p = argparse.ArgumentParser(description="Mobile Xray payload-path one-shot test.")
    p.add_argument("--api-url", default=os.getenv("API_URL", "https://api.granilink.com"))
    p.add_argument("--email", default=os.getenv("TEST_EMAIL", "rail@emteh.ru"))
    p.add_argument("--code", default=os.getenv("TEST_CODE"))
    p.add_argument("--token", default=os.getenv("TEST_TOKEN"))
    p.add_argument("--protocol", default="xray_vless")
    p.add_argument("--server-id", type=int, default=1)
    p.add_argument("--server-name", default="HU-BUD-01")
    p.add_argument("--device-id", default=f"payload-test-{uuid.uuid4().hex[:10]}")
    p.add_argument("--probe-url", action="append", default=["https://example.com/", "https://api.granilink.com/health"])
    args = p.parse_args()

    base_url = args.api_url.rstrip("/")
    _log(f"[1/7] auth via {base_url}")
    api = _auth(base_url, args.email, args.code, args.token)

    _log(f"[2/7] create-client protocol={args.protocol} device_id={args.device_id}")
    created = _create_client(
        base_url=base_url,
        token=api.token,
        server_id=args.server_id,
        device_id=args.device_id,
        protocol=args.protocol,
    )
    json_cfg = created.get("json_config")
    if not isinstance(json_cfg, dict):
        raise RuntimeError(f"create-client did not return json_config dict: {created}")

    device_db_id = _get_or_create_device_db_id(api.user_id, args.device_id)
    client_email = f"{api.user_id}_{device_db_id}@granivpn.com"
    _log(f"resolved xray client email marker: {client_email}")

    runtime_cfg = _build_xray_runtime_config(json_cfg, args.protocol)
    with tempfile.TemporaryDirectory(prefix="xray-payload-test-") as td:
        cfg_path = Path(td) / "config.json"
        cfg_path.write_text(json.dumps(runtime_cfg, ensure_ascii=False, indent=2), encoding="utf-8")
        cname = f"xray-payload-test-{uuid.uuid4().hex[:8]}"

        _log("[3/7] capture server start timestamp")
        start_local = _server_now_local(args.server_name)

        _log("[4/7] start temporary local xray client (docker)")
        _docker_start_xray(cfg_path, cname)
        try:
            _log("[5/7] run probes through socks5://127.0.0.1:10808")
            probe_results = []
            for u in args.probe_url:
                ok, details = _probe_via_socks(u)
                probe_results.append((u, ok, details))
                _log(f"probe {u} -> {'OK' if ok else 'FAIL'} ({details})")
        finally:
            _run(["docker", "rm", "-f", cname], check=False)

    _log("[6/7] capture server end timestamp and collect logs")
    end_local = _server_now_local(args.server_name)
    logs = _collect_server_window_logs(args.server_name, start_local, end_local, client_email)

    access = logs["access"]
    error = logs["error"]
    accepted_count = access.count(" accepted ")
    timeout_count = error.count("i/o timeout")
    probe_ok = all(ok for _, ok, _ in probe_results)

    _log("\n========== TEST REPORT ==========")
    _log(f"window_server_local: {start_local} .. {end_local}")
    _log(f"protocol: {args.protocol}")
    _log(f"device_id: {args.device_id}")
    _log(f"client_email_marker: {client_email}")
    _log(f"accepted_count: {accepted_count}")
    _log(f"timeout_count: {timeout_count}")
    _log(f"probe_all_ok: {probe_ok}")

    _log("\n-- access.log window --")
    _log(access or "[empty]")
    _log("\n-- error.log window --")
    _log(error or "[empty]")

    if accepted_count > 0 and probe_ok:
        _log("\nVERDICT: SUCCESS (server accepted traffic, probes succeeded)")
        return 0
    _log("\nVERDICT: FAIL (no accepted evidence and/or probes failed)")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())


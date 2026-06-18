import socket
import time
from datetime import datetime
from typing import List, Dict, Any, Optional

import requests
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from core.config import settings
from core.constants import XRAY_REALITY_DEFAULT_PORT
from core.database import get_db
from core.metrics import metrics_registry
from core.cache import cache_stats
from core.rbac import get_current_admin_user
from models.observability import ObservabilityIncident
from models.user import User
from models.server import Server
from services.remote_vpn_manager import RemoteVPNManager

router = APIRouter()

# Таймауты для диагностики (секунды)
DIAG_HTTP_TIMEOUT = 5
DIAG_TCP_TIMEOUT = 3


def _ping_url(url: str) -> Dict[str, Any]:
    """Пинг одного URL (GET), возвращает {url, elapsed_ms, ok, error?}."""
    start = time.monotonic()
    try:
        r = requests.get(url, timeout=DIAG_HTTP_TIMEOUT)
        elapsed_ms = int((time.monotonic() - start) * 1000)
        return {"url": url, "elapsed_ms": elapsed_ms, "ok": r.status_code < 400, "status_code": r.status_code}
    except Exception as e:
        elapsed_ms = int((time.monotonic() - start) * 1000)
        return {"url": url, "elapsed_ms": elapsed_ms, "ok": False, "error": str(e)}


def _ping_tcp(host: str, port: int) -> Dict[str, Any]:
    """Пинг TCP-порта (connect), возвращает {host, port, elapsed_ms, ok, error?}."""
    start = time.monotonic()
    try:
        sock = socket.create_connection((host, port), timeout=DIAG_TCP_TIMEOUT)
        sock.close()
        elapsed_ms = int((time.monotonic() - start) * 1000)
        return {"host": host, "port": port, "elapsed_ms": elapsed_ms, "ok": True}
    except Exception as e:
        elapsed_ms = int((time.monotonic() - start) * 1000)
        return {"host": host, "port": port, "elapsed_ms": elapsed_ms, "ok": False, "error": str(e)}


def _server_protocols(server: Server) -> List[str]:
    raw_protocols = getattr(server, "supported_protocols", None)
    protocols = raw_protocols if isinstance(raw_protocols, list) else []
    if not protocols:
        try:
            protocols = server.get_supported_protocols() if hasattr(server, "get_supported_protocols") else []
        except Exception:
            protocols = []
    if not protocols:
        protocols = ["graniwg"] if getattr(server, "graniwg_enabled", False) else ["xray_vless"]
    return protocols


def _check_graniwg(server: Server) -> Dict[str, Any]:
    host = server.ssh_host or server.ip_address
    port = int(server.wireguard_port or 51820)
    start = time.monotonic()
    payload: Dict[str, Any] = {
        "host": host,
        "port": port,
        "transport": "udp",
        "protocol": "graniwg",
        "check": "wg_show",
    }
    try:
        rm = RemoteVPNManager()
        cfg = rm.get_ssh_config(server)
        interface = getattr(server, "wireguard_interface", None) or "wg0"
        result = rm.ssh_manager.execute_command(
            cfg["host"],
            f"wg show {interface}",
            cfg["port"],
            cfg["username"],
            cfg.get("key_path"),
            cfg.get("key_content"),
            cfg.get("password"),
        )
        payload["elapsed_ms"] = int((time.monotonic() - start) * 1000)
        payload["ok"] = bool(result.get("success"))
        if not payload["ok"]:
            payload["error"] = result.get("stderr") or "wg show failed"
        return payload
    except Exception as e:
        payload["elapsed_ms"] = int((time.monotonic() - start) * 1000)
        payload["ok"] = False
        payload["error"] = str(e)
        return payload


def _to_int(value: Optional[str]) -> Optional[int]:
    if value is None:
        return None
    raw = str(value).strip()
    if not raw:
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def _build_egress_risk(
    *,
    conntrack_count: Optional[int],
    conntrack_max: Optional[int],
    ip_forward_enabled: Optional[bool],
    has_forward_accept_rule: Optional[bool],
) -> Dict[str, Any]:
    saturation: Optional[float] = None
    if conntrack_count is not None and conntrack_max and conntrack_max > 0:
        saturation = conntrack_count / conntrack_max

    level = "ok"
    reasons: List[str] = []
    if saturation is not None:
        if saturation >= 0.95:
            level = "critical"
            reasons.append("conntrack_saturation_ge_95pct")
        elif saturation >= 0.85:
            level = "warn"
            reasons.append("conntrack_saturation_ge_85pct")

    if ip_forward_enabled is False:
        level = "critical"
        reasons.append("ip_forward_disabled")
    if has_forward_accept_rule is False and level != "critical":
        level = "warn"
        reasons.append("forward_chain_accept_rule_not_detected")

    return {
        "level": level,
        "reasons": reasons,
        "conntrack_saturation": round(saturation, 4) if saturation is not None else None,
    }


def _build_egress_remediation_actions(risk_reasons: List[str]) -> List[str]:
    actions: List[str] = []
    if "conntrack_saturation_ge_95pct" in risk_reasons or "conntrack_saturation_ge_85pct" in risk_reasons:
        actions.append("Increase nf_conntrack_max and inspect conntrack churn (long-lived/mobile reconnect bursts).")
    if "ip_forward_disabled" in risk_reasons:
        actions.append("Enable net.ipv4.ip_forward=1 and persist via sysctl config.")
    if "forward_chain_accept_rule_not_detected" in risk_reasons:
        actions.append("Ensure FORWARD chain allows VPN tunnel traffic (iptables/nft forward accept policy).")
    if "ssh_audit_failed" in risk_reasons:
        actions.append("Fix SSH access/credentials to the node and rerun egress audit.")
    return actions


def _upsert_egress_incident(
    db: Session,
    *,
    server: Server,
    risk: Dict[str, Any],
    audit: Dict[str, Any],
    audit_error: Optional[str],
) -> ObservabilityIncident:
    now = time.time()
    incident_key = f"egress_audit:server:{server.id}"
    row = (
        db.query(ObservabilityIncident)
        .filter(
            ObservabilityIncident.incident_key == incident_key,
            ObservabilityIncident.status.in_(["open", "investigating", "mitigated"]),
        )
        .order_by(ObservabilityIncident.id.desc())
        .first()
    )
    level = str(risk.get("level") or "warn")
    severity = "P2" if level == "critical" else "P3"
    reasons = list(risk.get("reasons") or [])
    title = f"Egress audit risk on {server.name or server.id}"
    summary = f"risk={level}; reasons={','.join(reasons) if reasons else 'n/a'}"
    evidence = {
        "server_id": server.id,
        "server_name": server.name,
        "risk": risk,
        "audit": audit,
        "audit_error": audit_error,
        "detected_ts": int(now),
    }
    if row is None:
        row = ObservabilityIncident(
            incident_key=incident_key,
            incident_type="egress_audit_risk",
            severity=severity,
            status="open",
            title=title,
            summary=summary,
            evidence_json=evidence,
            first_seen_at=datetime.utcnow(),
            last_seen_at=datetime.utcnow(),
        )
        db.add(row)
    else:
        row.last_seen_at = datetime.utcnow()
        row.severity = severity
        row.title = title
        row.summary = summary
        row.evidence_json = evidence
    return row


@router.get("/metrics")
async def get_metrics(
    user: User = Depends(get_current_admin_user),
):
    if not settings.metrics_enabled:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Metrics are disabled",
        )
    payload = metrics_registry.snapshot()
    payload["cache"] = cache_stats()
    return payload


@router.get("/diagnostics/ping-upstreams")
async def diagnostics_ping_upstreams(
    user: User = Depends(get_current_admin_user),
    db: Session = Depends(get_db),
):
    """
    Диагностика доступности API и VPN-серверов.
    Возвращает время отклика (elapsed_ms) и статус (ok) для каждого upstream.
    Используется для разбора проблем на LTE/Beeline и проверки инфраструктуры.
    """
    result: Dict[str, List[Dict[str, Any]]] = {"api": [], "xray_servers": []}

    # 1) API URLs: основной + fallbacks (bootstrap)
    seen_api_urls: set = set()
    base = (settings.api_url or "").rstrip("/")
    if base:
        bootstrap_url = f"{base}/api/vpn/bootstrap"
        if bootstrap_url not in seen_api_urls:
            seen_api_urls.add(bootstrap_url)
            result["api"].append(_ping_url(bootstrap_url))
    fallbacks_raw = getattr(settings, "api_base_url_fallbacks", "") or ""
    for u in fallbacks_raw.split(","):
        u = u.strip().rstrip("/")
        if not u:
            continue
        url = f"{u}/vpn/bootstrap"
        if url not in seen_api_urls:
            seen_api_urls.add(url)
            result["api"].append(_ping_url(url))

    # 2) VPN-серверы: GRANIwg проверяем через wg show, Xray — TCP-порт.
    servers = db.query(Server).filter(Server.is_active == True).all()
    for srv in servers:
        protocols = _server_protocols(srv)
        has_graniwg = bool(getattr(srv, "graniwg_enabled", False)) or "graniwg" in protocols
        has_xray = any(str(p).startswith("xray_") for p in protocols)
        if has_graniwg and not has_xray:
            ping = _check_graniwg(srv)
        else:
            host = srv.ssh_host or srv.ip_address
            port = srv.xray_port or XRAY_REALITY_DEFAULT_PORT
            ping = _ping_tcp(host, port)
            ping["transport"] = "tcp"
            ping["protocol"] = "xray"
            ping["check"] = "tcp_connect"
        ping["server_id"] = srv.id
        ping["name"] = srv.name or ""
        result["xray_servers"].append(ping)

    return result


@router.get("/diagnostics/egress-audit")
async def diagnostics_egress_audit(
    user: User = Depends(get_current_admin_user),
    db: Session = Depends(get_db),
    create_incidents: bool = True,
):
    """
    SSH-аудит data-plane готовности нод:
    - conntrack saturation
    - ip_forward
    - наличие FORWARD ACCEPT правила
    - базовая сводка TCP/UDP сокетов (ss -s)
    """
    _ = user
    servers = db.query(Server).filter(Server.is_active == True).all()
    manager = RemoteVPNManager()
    if not manager.ssh_manager:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="SSH manager unavailable on this API instance",
        )

    items: List[Dict[str, Any]] = []
    incidents: List[Dict[str, Any]] = []
    for srv in servers:
        node = {
            "server_id": srv.id,
            "name": srv.name or "",
            "host": srv.ssh_host or srv.ip_address,
        }
        try:
            ssh = manager.get_ssh_config(srv)
            def _run(cmd: str) -> Dict[str, Any]:
                return manager.ssh_manager.execute_command(
                    ssh["host"],
                    cmd,
                    ssh["port"],
                    ssh["username"],
                    ssh.get("key_path"),
                    ssh.get("key_content"),
                    ssh.get("password"),
                )

            ct_count_raw = _run(
                "sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || "
                "cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo"
            )
            ct_max_raw = _run(
                "sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || "
                "cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo"
            )
            ip_forward_raw = _run(
                "sysctl -n net.ipv4.ip_forward 2>/dev/null || "
                "cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo"
            )
            forward_rule_raw = _run(
                "iptables -S FORWARD 2>/dev/null | sed -n '1,40p'; "
                "nft list chain inet filter forward 2>/dev/null | sed -n '1,40p'"
            )
            ss_summary_raw = _run("ss -s 2>/dev/null | tr '\n' ';'")

            conntrack_count = _to_int(ct_count_raw.get("stdout"))
            conntrack_max = _to_int(ct_max_raw.get("stdout"))
            ip_forward_enabled = _to_int(ip_forward_raw.get("stdout")) == 1
            fw_text = (forward_rule_raw.get("stdout") or "").lower()
            has_forward_accept_rule = "accept" in fw_text

            risk = _build_egress_risk(
                conntrack_count=conntrack_count,
                conntrack_max=conntrack_max,
                ip_forward_enabled=ip_forward_enabled,
                has_forward_accept_rule=has_forward_accept_rule,
            )
            node["audit"] = {
                "conntrack_count": conntrack_count,
                "conntrack_max": conntrack_max,
                "ip_forward_enabled": ip_forward_enabled,
                "has_forward_accept_rule": has_forward_accept_rule,
                "socket_summary": (ss_summary_raw.get("stdout") or "").strip()[:500],
            }
            node["risk"] = risk
            node["remediation"] = _build_egress_remediation_actions(risk.get("reasons") or [])
        except Exception as e:
            node["risk"] = {"level": "critical", "reasons": ["ssh_audit_failed"], "conntrack_saturation": None}
            node["audit_error"] = str(e)
            node["audit"] = {}
            node["remediation"] = _build_egress_remediation_actions(["ssh_audit_failed"])

        if create_incidents and node.get("risk", {}).get("level") in {"warn", "critical"}:
            incident = _upsert_egress_incident(
                db,
                server=srv,
                risk=node["risk"],
                audit=node.get("audit", {}),
                audit_error=node.get("audit_error"),
            )
            incidents.append(
                {
                    "id": incident.id,
                    "incident_key": incident.incident_key,
                    "server_id": srv.id,
                    "severity": incident.severity,
                    "status": incident.status,
                }
            )
        items.append(node)

    if create_incidents and incidents:
        db.commit()

    summary = {
        "total": len(items),
        "critical": len([i for i in items if i.get("risk", {}).get("level") == "critical"]),
        "warn": len([i for i in items if i.get("risk", {}).get("level") == "warn"]),
        "ok": len([i for i in items if i.get("risk", {}).get("level") == "ok"]),
    }
    return {"summary": summary, "items": items, "incidents": incidents}

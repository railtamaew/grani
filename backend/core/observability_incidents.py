from __future__ import annotations

from datetime import datetime
from typing import Any, Optional

from sqlalchemy.orm import Session

from models.observability import ObservabilityIncident


def classify_root_cause_from_client_log(
    *,
    event_type: str,
    message: Optional[str],
    error_details: Optional[dict[str, Any]],
) -> Optional[str]:
    details = error_details or {}
    msg = (message or "").strip().lower()
    et = (event_type or "").strip().lower()

    if et == "connection_error" and msg == "connectivity_commit_failed":
        public_ok = details.get("public_ok")
        api_ok = details.get("api_ok")
        if public_ok is False and api_ok is True:
            return "data_plane_egress_timeout_public_only"
        if public_ok is False and api_ok is False:
            return "node_unreachable_or_xray_inactive"
        return "data_plane_degraded_commit_gate"

    if et == "connectivity_probe":
        public_ok = details.get("public_ok")
        api_ok = details.get("api_ok")
        public_class = str(details.get("public_failure_class") or "").strip().lower()
        api_class = str(details.get("api_failure_class") or "").strip().lower()
        if public_ok is False and api_ok is True and public_class == "timeout":
            return "data_plane_egress_timeout_public_only"
        if public_class == "tcp_refused" or api_class == "tcp_refused":
            return "node_unreachable_or_xray_inactive"
        if public_class == "dns_error" or api_class == "dns_error":
            return "dns_resolution_failure"

    return None


def upsert_session_connectivity_incident(
    db: Session,
    *,
    vpn_session_id: str,
    root_cause: str,
    user_id: Optional[int],
    server_id: Optional[int],
    device_id: Optional[int],
    protocol: Optional[str],
    evidence: Optional[dict[str, Any]] = None,
) -> ObservabilityIncident:
    now = datetime.utcnow()
    incident_key = f"session_diag:{vpn_session_id}:{root_cause}"
    severity_map = {
        "node_unreachable_or_xray_inactive": "P2",
        "data_plane_egress_timeout_public_only": "P2",
        "data_plane_degraded_commit_gate": "P3",
        "dns_resolution_failure": "P3",
    }
    severity = severity_map.get(root_cause, "P3")
    row = (
        db.query(ObservabilityIncident)
        .filter(
            ObservabilityIncident.incident_key == incident_key,
            ObservabilityIncident.status.in_(["open", "investigating", "mitigated"]),
        )
        .order_by(ObservabilityIncident.id.desc())
        .first()
    )
    payload = dict(evidence or {})
    payload.update(
        {
            "vpn_session_id": vpn_session_id,
            "root_cause": root_cause,
            "user_id": user_id,
            "server_id": server_id,
            "device_id": device_id,
            "protocol": protocol,
        }
    )
    title = f"Session diagnostic: {root_cause}"
    summary = f"Auto-created from client logs for vpn_session_id={vpn_session_id}"
    if row is None:
        row = ObservabilityIncident(
            incident_key=incident_key,
            incident_type="session_connectivity_failure",
            severity=severity,
            status="open",
            title=title,
            summary=summary,
            evidence_json=payload,
            first_seen_at=now,
            last_seen_at=now,
        )
        db.add(row)
    else:
        row.last_seen_at = now
        row.severity = severity
        row.title = title
        row.summary = summary
        row.evidence_json = payload
    return row

from datetime import datetime, timedelta
from typing import Any, Optional
import base64
import json

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import String, and_, func, not_, or_, select
from sqlalchemy.orm import Session, aliased

from core.database import get_db
from core.rbac import get_current_admin_user
from models.client_log import ClientLog
from models.observability import (
    EventDictionary,
    ObservabilityEvent,
    ObservabilityIncident,
    ObservabilityIncidentComment,
)
from models.server import ConnectionLog, Server
from models.telemetry import TelemetryEvent
from models.user import User
from models.user import Device
from models.payment import Payment
from core.config import settings

router = APIRouter(prefix="/api/admin/observability", tags=["admin-observability"])

_SLA_TARGETS = {
    "P1": 15,  # minutes
    "P2": 60,
    "P3": 240,
    "P4": 1440,
}

_TIMELINE_GRAINS = {
    "minute": "minute",
    "hour": "hour",
    "day": "day",
}


def _bucket_expr(column, grain: str):
    return func.date_trunc(_TIMELINE_GRAINS[grain], column)


def _bucket_key(value: datetime) -> str:
    return value.replace(microsecond=0).isoformat() if value else ""


def _empty_timeline_bucket(bucket: datetime) -> dict[str, Any]:
    return {
        "bucket": _bucket_key(bucket),
        "connection_attempts": 0,
        "connection_success": 0,
        "traffic_confirmed": 0,
        "connection_errors": 0,
        "verify_warnings": 0,
        "new_users": 0,
        "login_seen": 0,
        "payments_total": 0,
        "payments_completed": 0,
        "payments_failed": 0,
    }


@router.get("/metrics/product-timeline")
async def get_product_timeline(
    from_time: Optional[str] = None,
    to_time: Optional[str] = None,
    grain: str = "hour",
    admin_user: User = Depends(get_current_admin_user),
    db: Session = Depends(get_db),
):
    _ = admin_user
    if grain not in _TIMELINE_GRAINS:
        raise HTTPException(status_code=400, detail="grain must be minute, hour, or day")

    dt_to = _parse_dt(to_time) if to_time else datetime.utcnow()
    dt_from = _parse_dt(from_time) if from_time else dt_to - timedelta(hours=24)
    if dt_from >= dt_to:
        raise HTTPException(status_code=400, detail="from_time must be before to_time")
    max_window = timedelta(days=31)
    if dt_to - dt_from > max_window:
        raise HTTPException(status_code=400, detail="timeline window must be <= 31 days")

    bucket = _bucket_expr(ClientLog.created_at, grain).label("bucket")
    session_key = func.coalesce(
        ClientLog.vpn_session_id,
        func.cast(ClientLog.id, String),
    )
    success_condition = or_(
        ClientLog.event_type == "connection_success",
        and_(
            ClientLog.event_type == "connection_stage",
            ClientLog.message == "connected_local",
        ),
        ClientLog.event_type == "traffic_first_seen",
    )
    traffic_log = aliased(ClientLog)
    traffic_seen_before = (
        select(traffic_log.id)
        .where(
            traffic_log.event_type == "traffic_first_seen",
            traffic_log.vpn_session_id == ClientLog.vpn_session_id,
            traffic_log.created_at <= ClientLog.created_at,
        )
        .limit(1)
        .exists()
    )
    stale_handshake_condition = and_(
        ClientLog.event_type == "connection_error",
        or_(
            ClientLog.message == "node_data_verify_failed",
            ClientLog.error_code == "simple_vpn_node_data_verify_failed",
            ClientLog.error_details.op("->>")("reason") == "stale_or_missing_handshake",
        ),
    )
    verify_warning_condition = and_(
        stale_handshake_condition,
        ClientLog.vpn_session_id.isnot(None),
        traffic_seen_before,
    )
    real_error_condition = and_(
        ClientLog.event_type == "connection_error",
        not_(verify_warning_condition),
    )
    client_rows = (
        db.query(
            bucket,
            func.count(func.distinct(session_key)).filter(ClientLog.event_type == "connection_start").label("connection_attempts"),
            func.count(func.distinct(session_key)).filter(success_condition).label("connection_success"),
            func.count(func.distinct(session_key)).filter(ClientLog.event_type == "traffic_first_seen").label("traffic_confirmed"),
            func.count(func.distinct(session_key)).filter(real_error_condition).label("connection_errors"),
            func.count(func.distinct(session_key)).filter(verify_warning_condition).label("verify_warnings"),
        )
        .filter(ClientLog.created_at >= dt_from, ClientLog.created_at <= dt_to)
        .group_by(bucket)
        .all()
    )

    user_created_bucket = _bucket_expr(User.created_at, grain).label("bucket")
    new_user_rows = (
        db.query(user_created_bucket, func.count(User.id).label("new_users"))
        .filter(User.created_at >= dt_from, User.created_at <= dt_to)
        .group_by(user_created_bucket)
        .all()
    )

    user_login_bucket = _bucket_expr(User.last_login_at, grain).label("bucket")
    login_rows = (
        db.query(user_login_bucket, func.count(User.id).label("login_seen"))
        .filter(User.last_login_at >= dt_from, User.last_login_at <= dt_to)
        .group_by(user_login_bucket)
        .all()
    )

    payment_bucket = _bucket_expr(Payment.created_at, grain).label("bucket")
    payment_rows = (
        db.query(
            payment_bucket,
            func.count(Payment.id).label("payments_total"),
            func.count(Payment.id).filter(Payment.status == "completed").label("payments_completed"),
            func.count(Payment.id).filter(Payment.status.in_(["failed", "cancelled", "refunded"])).label("payments_failed"),
        )
        .filter(Payment.created_at >= dt_from, Payment.created_at <= dt_to)
        .group_by(payment_bucket)
        .all()
    )

    buckets: dict[str, dict[str, Any]] = {}

    def ensure(raw_bucket: datetime) -> dict[str, Any]:
        key = _bucket_key(raw_bucket)
        if key not in buckets:
            buckets[key] = _empty_timeline_bucket(raw_bucket)
        return buckets[key]

    for row in client_rows:
        item = ensure(row.bucket)
        item["connection_attempts"] = int(row.connection_attempts or 0)
        item["connection_success"] = int(row.connection_success or 0)
        item["traffic_confirmed"] = int(row.traffic_confirmed or 0)
        item["connection_errors"] = int(row.connection_errors or 0)
        item["verify_warnings"] = int(row.verify_warnings or 0)

    for row in new_user_rows:
        ensure(row.bucket)["new_users"] = int(row.new_users or 0)

    for row in login_rows:
        ensure(row.bucket)["login_seen"] = int(row.login_seen or 0)

    for row in payment_rows:
        item = ensure(row.bucket)
        item["payments_total"] = int(row.payments_total or 0)
        item["payments_completed"] = int(row.payments_completed or 0)
        item["payments_failed"] = int(row.payments_failed or 0)

    items = [buckets[key] for key in sorted(buckets.keys())]
    totals = {
        "connection_attempts": sum(item["connection_attempts"] for item in items),
        "connection_success": sum(item["connection_success"] for item in items),
        "traffic_confirmed": sum(item["traffic_confirmed"] for item in items),
        "connection_errors": sum(item["connection_errors"] for item in items),
        "verify_warnings": sum(item["verify_warnings"] for item in items),
        "new_users": sum(item["new_users"] for item in items),
        "login_seen": sum(item["login_seen"] for item in items),
        "payments_total": sum(item["payments_total"] for item in items),
        "payments_completed": sum(item["payments_completed"] for item in items),
        "payments_failed": sum(item["payments_failed"] for item in items),
    }
    return {
        "from_time": dt_from.isoformat(),
        "to_time": dt_to.isoformat(),
        "grain": grain,
        "items": items,
        "totals": totals,
        "notes": {
            "login_seen": "Approximation from users.last_login_at; full auth history requires dedicated auth event logging.",
            "connection_metrics": "VPN counters are distinct vpn_session_id counts; rows without session id fall back to the log row id.",
            "connection_success": "Distinct sessions with connection_success, legacy connected_local stage, or traffic_first_seen.",
            "traffic_confirmed": "Distinct sessions with server-side traffic_first_seen verification.",
            "connection_errors": "Real VPN errors; stale handshake verify events are excluded when the same session already had traffic_first_seen.",
            "verify_warnings": "Stale/missing handshake verify events after traffic was already confirmed in the same session.",
        },
    }


@router.get("/metrics/connectivity-summary")
async def get_connectivity_summary(
    hours: int = 24,
    admin_user: User = Depends(get_current_admin_user),
    db: Session = Depends(get_db),
):
    _ = admin_user
    hours = max(1, min(hours, 168))
    dt_from = datetime.utcnow() - timedelta(hours=hours)

    # 1) Connection duration quantiles by protocol
    duration_rows = (
        db.query(
            ClientLog.protocol.label("protocol"),
            func.count(ClientLog.id).label("samples"),
            func.percentile_cont(0.5).within_group(ClientLog.connection_duration_ms).label("p50_ms"),
            func.percentile_cont(0.95).within_group(ClientLog.connection_duration_ms).label("p95_ms"),
            func.avg(ClientLog.connection_duration_ms).label("avg_ms"),
        )
        .filter(
            ClientLog.created_at >= dt_from,
            ClientLog.event_type == "connection_end",
            ClientLog.connection_duration_ms.isnot(None),
            ClientLog.connection_duration_ms > 0,
        )
        .group_by(ClientLog.protocol)
        .all()
    )

    duration_by_protocol = {
        (row.protocol or "unknown"): {
            "samples": int(row.samples or 0),
            "p50_ms": int(row.p50_ms or 0),
            "p95_ms": int(row.p95_ms or 0),
            "avg_ms": int(row.avg_ms or 0),
        }
        for row in duration_rows
    }

    # 2) Stage errors
    stage_rows = (
        db.query(
            ClientLog.protocol.label("protocol"),
            func.coalesce(ClientLog.error_details["stage"].astext, "unknown").label("stage"),
            func.count(ClientLog.id).label("errors"),
        )
        .filter(
            ClientLog.created_at >= dt_from,
            ClientLog.event_type == "connection_error",
        )
        .group_by(ClientLog.protocol, func.coalesce(ClientLog.error_details["stage"].astext, "unknown"))
        .all()
    )
    stage_errors: dict[str, dict[str, int]] = {}
    for row in stage_rows:
        protocol = row.protocol or "unknown"
        stage = row.stage or "unknown"
        stage_errors.setdefault(protocol, {})
        stage_errors[protocol][stage] = int(row.errors or 0)

    # 3) Degraded retry rate by protocol
    protocol_rows = (
        db.query(
            ClientLog.protocol.label("protocol"),
            func.count(ClientLog.id).filter(ClientLog.message == "connected_degraded_retry").label("degraded_count"),
            func.count(ClientLog.id).filter(ClientLog.event_type == "connection_start").label("starts_count"),
        )
        .filter(
            ClientLog.created_at >= dt_from,
            ClientLog.protocol.in_(["xray_vless", "xray_reality", "xray_vmess"]),
        )
        .group_by(ClientLog.protocol)
        .all()
    )
    degraded_rate = {}
    for row in protocol_rows:
        starts = int(row.starts_count or 0)
        degraded = int(row.degraded_count or 0)
        degraded_rate[row.protocol or "unknown"] = {
            "degraded_count": degraded,
            "starts_count": starts,
            "degraded_rate_pct": round((degraded / starts) * 100, 2) if starts > 0 else 0.0,
        }

    # 3b) Success rate by protocol
    success_rows = (
        db.query(
            ClientLog.protocol.label("protocol"),
            func.count(ClientLog.id).filter(ClientLog.event_type == "connection_success").label("success_count"),
            func.count(ClientLog.id).filter(ClientLog.event_type == "connection_start").label("starts_count"),
        )
        .filter(
            ClientLog.created_at >= dt_from,
            ClientLog.protocol.in_(["xray_vless", "xray_reality", "xray_vmess"]),
        )
        .group_by(ClientLog.protocol)
        .all()
    )
    success_rate = {}
    for row in success_rows:
        starts = int(row.starts_count or 0)
        success = int(row.success_count or 0)
        success_rate[row.protocol or "unknown"] = {
            "success_count": success,
            "starts_count": starts,
            "success_rate_pct": round((success / starts) * 100, 2) if starts > 0 else 0.0,
        }

    # 4) Network split from error_details.network_type
    network_rows = (
        db.query(
            ClientLog.protocol.label("protocol"),
            func.coalesce(ClientLog.error_details["network_type"].astext, "unknown").label("network_type"),
            func.count(ClientLog.id).filter(ClientLog.event_type == "connection_error").label("errors"),
            func.count(ClientLog.id).filter(ClientLog.event_type == "connection_start").label("starts"),
        )
        .filter(ClientLog.created_at >= dt_from)
        .group_by(ClientLog.protocol, func.coalesce(ClientLog.error_details["network_type"].astext, "unknown"))
        .all()
    )
    network_split: dict[str, dict[str, dict[str, int]]] = {}
    for row in network_rows:
        protocol = row.protocol or "unknown"
        nt = row.network_type or "unknown"
        network_split.setdefault(protocol, {})
        network_split[protocol][nt] = {
            "errors": int(row.errors or 0),
            "starts": int(row.starts or 0),
        }

    # 5) Runtime guard signal
    dataplane_not_ready_after_apply = (
        db.query(func.count(ClientLog.id))
        .filter(
            ClientLog.created_at >= dt_from,
            ClientLog.event_type == "connection_error",
            ClientLog.error_details.cast(String).ilike("%dataplane_not_ready_after_apply%"),
        )
        .scalar()
        or 0
    )

    return {
        "window_hours": hours,
        "duration_by_protocol": duration_by_protocol,
        "stage_errors": stage_errors,
        "degraded_rate": degraded_rate,
        "success_rate": success_rate,
        "network_split": network_split,
        "signals": {
            "dataplane_not_ready_after_apply": int(dataplane_not_ready_after_apply),
        },
    }


def _as_hash_text(value: Optional[str]) -> str:
    return (value or "").strip()


def _incident_sla_payload(row: ObservabilityIncident) -> dict:
    now = datetime.utcnow()
    started = row.first_seen_at or now
    age_minutes = max(0, int((now - started).total_seconds() // 60))
    target = _SLA_TARGETS.get(row.severity, 240)
    is_resolved = row.status == "resolved"
    return {
        "age_minutes": age_minutes,
        "sla_target_minutes": target,
        "sla_breached": (not is_resolved) and age_minutes > target,
    }


def _parse_dt(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise HTTPException(status_code=400, detail=f"Invalid datetime: {value}")


def _encode_cursor(payload: dict) -> str:
    raw = json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    return base64.urlsafe_b64encode(raw).decode("ascii")


def _decode_cursor(cursor: Optional[str]) -> Optional[dict]:
    if not cursor:
        return None
    try:
        raw = base64.urlsafe_b64decode(cursor.encode("ascii"))
        data = json.loads(raw.decode("utf-8"))
        if not isinstance(data, dict):
            return None
        return data
    except Exception:
        return None


def _build_events_cursor(mode: str, row: ObservabilityEvent) -> Optional[str]:
    if not row or not row.event_time:
        return None
    return _encode_cursor(
        {
            "mode": mode,
            "t": row.event_time.isoformat(),
            "id": row.id,
        }
    )


def _build_incidents_cursor(mode: str, row: ObservabilityIncident, direction: str) -> Optional[str]:
    if not row or not row.last_seen_at:
        return None
    return _encode_cursor(
        {
            "mode": mode,
            "t": row.last_seen_at.isoformat(),
            "id": row.id,
            "dir": direction,
        }
    )


def _event_base_payload(row: ObservabilityEvent) -> dict:
    return {
        "id": row.id,
        "event_time": row.event_time.isoformat() if row.event_time else None,
        "event_name": row.event_name,
        "severity": row.severity,
        "source": row.source,
        "request_id": row.request_id,
        "trace_id": row.trace_id,
        "vpn_session_id": row.vpn_session_id,
        "user_id": row.user_id,
        "device_id": row.device_id,
        "server_id": row.server_id,
        "protocol": row.protocol,
        "stage": row.stage,
        "outcome": row.outcome,
        "reason_code": row.reason_code,
        "message": row.message,
        "attrs": row.attrs_json or {},
    }


def _pick_nearest_log(logs: list, target_dt: Optional[datetime], ts_attr: str):
    if not logs:
        return None
    if target_dt is None:
        return logs[0]
    best = None
    best_delta = None
    for log in logs:
        log_dt = getattr(log, ts_attr, None)
        if log_dt is None:
            continue
        delta = abs((log_dt - target_dt).total_seconds())
        if best is None or delta < best_delta:
            best = log
            best_delta = delta
    return best or logs[0]


def _safe_text(value: Any) -> str:
    return (str(value or "")).strip().lower()


def _classify_failure_from_error_text(raw: Any) -> str:
    text = _safe_text(raw)
    if not text:
        return ""
    if "connection refused" in text or "tcp_refused" in text:
        return "tcp_refused"
    if "timed out" in text or "timeout" in text:
        return "timeout"
    if "network is unreachable" in text or "unreachable" in text:
        return "network_unreachable"
    if "unable to resolve host" in text or "name or service not known" in text or "dns" in text:
        return "dns_error"
    if "ssl" in text or "tls" in text or "handshake" in text:
        return "tls_error"
    return "other"


def _classify_session_failure(
    *,
    client_logs: list[ClientLog],
    events: list[ObservabilityEvent],
) -> dict[str, Any]:
    has_commit_failed = False
    has_public_timeout = False
    has_api_timeout = False
    has_public_only_fail = False
    has_tcp_refused = False
    has_dns_error = False
    has_tls_error = False
    has_network_unreachable = False
    has_apply_not_confirmed = False

    for row in client_logs:
        details = row.error_details or {}
        if row.event_type == "connection_error" and _safe_text(row.message) == "connectivity_commit_failed":
            has_commit_failed = True
        if row.event_type != "connectivity_probe":
            continue
        public_ok = details.get("public_ok")
        api_ok = details.get("api_ok")
        public_class = _safe_text(details.get("public_failure_class"))
        api_class = _safe_text(details.get("api_failure_class"))
        if not public_class:
            public_class = _classify_failure_from_error_text(details.get("public_err"))
        if not api_class:
            api_class = _classify_failure_from_error_text(details.get("api_err"))
        if public_ok is False and api_ok is True:
            has_public_only_fail = True
        if public_class == "timeout":
            has_public_timeout = True
        if api_class == "timeout":
            has_api_timeout = True
        if public_class == "tcp_refused" or api_class == "tcp_refused":
            has_tcp_refused = True
        if public_class == "dns_error" or api_class == "dns_error":
            has_dns_error = True
        if public_class == "tls_error" or api_class == "tls_error":
            has_tls_error = True
        if public_class == "network_unreachable" or api_class == "network_unreachable":
            has_network_unreachable = True

    for row in events:
        reason = _safe_text(row.reason_code)
        message = _safe_text(row.message)
        stage = _safe_text(row.stage)
        if "apply_not_confirmed" in reason or "apply timeout" in message:
            has_apply_not_confirmed = True
        if stage == "apply" and row.outcome == "failure":
            has_apply_not_confirmed = True

    if has_apply_not_confirmed:
        return {
            "root_cause": "control_plane_apply_not_confirmed",
            "confidence": "high",
            "explanation": "Apply phase was not confirmed for this session.",
        }
    if has_tcp_refused:
        return {
            "root_cause": "node_unreachable_or_xray_inactive",
            "confidence": "high",
            "explanation": "Connectivity probe detected tcp_refused on public/API path.",
        }
    if has_public_only_fail and has_public_timeout:
        return {
            "root_cause": "data_plane_egress_timeout_public_only",
            "confidence": "high",
            "explanation": "Public probe timed out while API probe stayed healthy.",
        }
    if has_public_only_fail and has_tls_error:
        return {
            "root_cause": "data_plane_tls_handshake_public_only",
            "confidence": "high",
            "explanation": "Public probe failed with TLS/SSL handshake while API probe stayed healthy.",
        }
    if has_public_only_fail and has_network_unreachable:
        return {
            "root_cause": "data_plane_network_unreachable_public_only",
            "confidence": "high",
            "explanation": "Public probe failed with network unreachable while API probe stayed healthy.",
        }
    if has_commit_failed and (has_public_timeout or has_api_timeout):
        return {
            "root_cause": "data_plane_degraded_commit_gate",
            "confidence": "medium",
            "explanation": "Commit gate failed after repeated connectivity probe timeouts.",
        }
    if has_dns_error:
        return {
            "root_cause": "dns_resolution_failure",
            "confidence": "medium",
            "explanation": "Connectivity probe reported DNS resolution failures.",
        }
    if has_commit_failed:
        return {
            "root_cause": "connectivity_commit_failed_unclassified",
            "confidence": "low",
            "explanation": "Commit gate failed but probe failure class is not explicit.",
        }
    return {
        "root_cause": "unknown",
        "confidence": "low",
        "explanation": "No deterministic failure signature was found.",
    }


def _upsert_session_diagnostic_incident(
    db: Session,
    *,
    vpn_session_id: str,
    classification: dict[str, Any],
    event_rows: list[ObservabilityEvent],
    client_rows: list[ClientLog],
) -> ObservabilityIncident:
    root_cause = (classification.get("root_cause") or "unknown").strip()
    confidence = (classification.get("confidence") or "low").strip().lower()
    severity_map = {
        "control_plane_apply_not_confirmed": "P2",
        "node_unreachable_or_xray_inactive": "P2",
        "data_plane_egress_timeout_public_only": "P2",
        "data_plane_degraded_commit_gate": "P3",
        "dns_resolution_failure": "P3",
    }
    severity = severity_map.get(root_cause, "P3")
    now = datetime.utcnow()
    incident_key = f"session_diag:{vpn_session_id}:{root_cause}"
    row = (
        db.query(ObservabilityIncident)
        .filter(
            ObservabilityIncident.incident_key == incident_key,
            ObservabilityIncident.status.in_(["open", "investigating", "mitigated"]),
        )
        .order_by(ObservabilityIncident.id.desc())
        .first()
    )
    first_event = event_rows[0] if event_rows else None
    first_client = client_rows[0] if client_rows else None
    evidence = {
        "vpn_session_id": vpn_session_id,
        "root_cause": root_cause,
        "confidence": confidence,
        "event_count": len(event_rows),
        "client_log_count": len(client_rows),
        "first_event_id": first_event.id if first_event else None,
        "first_client_log_id": first_client.id if first_client else None,
        "server_id": first_event.server_id if first_event else (first_client.server_id if first_client else None),
        "user_id": first_event.user_id if first_event else (first_client.user_id if first_client else None),
    }
    title = f"Session diagnostic: {root_cause}"
    summary = classification.get("explanation") or "Automatic incident from session diagnostics"
    if row is None:
        row = ObservabilityIncident(
            incident_key=incident_key,
            incident_type="session_connectivity_failure",
            severity=severity,
            status="open",
            title=title,
            summary=summary,
            evidence_json=evidence,
            first_seen_at=now,
            last_seen_at=now,
        )
        db.add(row)
        db.flush()
    else:
        row.last_seen_at = now
        row.severity = severity
        row.title = title
        row.summary = summary
        row.evidence_json = evidence
        db.flush()
    return row


@router.get("/events")
async def get_events(
    from_time: Optional[str] = None,
    to_time: Optional[str] = None,
    limit: int = 200,
    cursor: Optional[str] = None,
    user_id: Optional[int] = None,
    device_id: Optional[int] = None,
    server_id: Optional[int] = None,
    vpn_session_id: Optional[str] = None,
    request_id: Optional[str] = None,
    trace_id: Optional[str] = None,
    event_name: Optional[str] = None,
    severity: Optional[str] = None,
    protocol: Optional[str] = None,
    reason_code: Optional[str] = None,
    cursor_direction: str = "next",
    detail_level: str = "basic",
    correlation_window_seconds: int = 120,
    admin_user: User = Depends(get_current_admin_user),
    db: Session = Depends(get_db),
):
    _ = admin_user
    configured_backend = (settings.observability_events_backend or "postgres").lower().strip()
    if configured_backend not in ("postgres", "clickhouse", "loki"):
        configured_backend = "postgres"
    # External analytics backends are introduced behind this flag.
    # Until adapters are enabled in runtime, fallback stays deterministic.
    effective_backend = "postgres" if configured_backend in ("postgres", "clickhouse", "loki") else "postgres"
    limit = max(1, min(limit, 2000))
    cursor_data = _decode_cursor(cursor)
    dt_from = _parse_dt(from_time)
    dt_to = _parse_dt(to_time)

    query = db.query(ObservabilityEvent)
    if dt_from:
        query = query.filter(ObservabilityEvent.event_time >= dt_from)
    if dt_to:
        query = query.filter(ObservabilityEvent.event_time <= dt_to)
    if user_id:
        query = query.filter(ObservabilityEvent.user_id == user_id)
    if device_id:
        query = query.filter(ObservabilityEvent.device_id == device_id)
    if server_id:
        query = query.filter(ObservabilityEvent.server_id == server_id)
    if vpn_session_id:
        query = query.filter(ObservabilityEvent.vpn_session_id == vpn_session_id)
    if request_id:
        query = query.filter(ObservabilityEvent.request_id == request_id)
    if trace_id:
        query = query.filter(ObservabilityEvent.trace_id == trace_id)
    if event_name:
        query = query.filter(ObservabilityEvent.event_name == event_name)
    if severity:
        query = query.filter(ObservabilityEvent.severity == severity)
    if protocol:
        query = query.filter(ObservabilityEvent.protocol == protocol)
    if reason_code:
        query = query.filter(ObservabilityEvent.reason_code == reason_code)

    if cursor_data and cursor_data.get("mode") in ("events_keyset", "events_keyset_prev"):
        cur_time = _parse_dt(cursor_data.get("t"))
        cur_id = cursor_data.get("id")
        if cur_time and isinstance(cur_id, int):
            if cursor_direction == "prev":
                query = query.filter(
                    or_(
                        ObservabilityEvent.event_time > cur_time,
                        and_(
                            ObservabilityEvent.event_time == cur_time,
                            ObservabilityEvent.id > cur_id,
                        ),
                    )
                )
                rows = query.order_by(ObservabilityEvent.event_time.asc(), ObservabilityEvent.id.asc()).limit(limit + 1).all()
                has_more = len(rows) > limit
                rows = rows[:limit]
                rows.reverse()
            else:
                query = query.filter(
                    or_(
                        ObservabilityEvent.event_time < cur_time,
                        and_(
                            ObservabilityEvent.event_time == cur_time,
                            ObservabilityEvent.id < cur_id,
                        ),
                    )
                )
                rows = query.order_by(ObservabilityEvent.event_time.desc(), ObservabilityEvent.id.desc()).limit(limit + 1).all()
                has_more = len(rows) > limit
                rows = rows[:limit]
        else:
            rows = query.order_by(ObservabilityEvent.event_time.desc(), ObservabilityEvent.id.desc()).limit(limit + 1).all()
            has_more = len(rows) > limit
            rows = rows[:limit]
    else:
        rows = query.order_by(ObservabilityEvent.event_time.desc(), ObservabilityEvent.id.desc()).limit(limit + 1).all()
        has_more = len(rows) > limit
        rows = rows[:limit]
    detail_level = (detail_level or "basic").lower().strip()
    if detail_level not in ("basic", "enriched"):
        raise HTTPException(status_code=400, detail="detail_level must be 'basic' or 'enriched'")

    items = [_event_base_payload(row) for row in rows]

    # Heavy analytics / enrich path is opt-in only.
    if detail_level == "enriched" and rows:
        correlation_window_seconds = max(30, min(correlation_window_seconds, 3600))
        user_ids = {row.user_id for row in rows if row.user_id is not None}
        device_ids = {row.device_id for row in rows if row.device_id is not None}
        server_ids = {row.server_id for row in rows if row.server_id is not None}
        session_ids = {row.vpn_session_id for row in rows if row.vpn_session_id}
        event_times = [row.event_time for row in rows if row.event_time is not None]

        user_map = {}
        device_map = {}
        server_map = {}
        client_logs_by_session = {}
        connection_logs_by_session = {}
        telemetry_logs_by_session = {}

        if user_ids:
            user_rows = db.query(User).filter(User.id.in_(user_ids)).all()
            user_map = {u.id: u for u in user_rows}
        if device_ids:
            dev_rows = db.query(Device).filter(Device.id.in_(device_ids)).all()
            device_map = {d.id: d for d in dev_rows}
        if server_ids:
            srv_rows = db.query(Server).filter(Server.id.in_(server_ids)).all()
            server_map = {s.id: s for s in srv_rows}

        if session_ids and event_times:
            dt_min = min(event_times) - timedelta(seconds=correlation_window_seconds)
            dt_max = max(event_times) + timedelta(seconds=correlation_window_seconds)

            cl_rows = (
                db.query(ClientLog)
                .filter(
                    ClientLog.vpn_session_id.in_(session_ids),
                    ClientLog.created_at >= dt_min,
                    ClientLog.created_at <= dt_max,
                )
                .order_by(ClientLog.created_at.desc(), ClientLog.id.desc())
                .limit(10000)
                .all()
            )
            for log in cl_rows:
                if log.vpn_session_id:
                    client_logs_by_session.setdefault(log.vpn_session_id, []).append(log)

            conn_rows = (
                db.query(ConnectionLog)
                .filter(
                    ConnectionLog.vpn_session_id.in_(session_ids),
                    ConnectionLog.connected_at >= dt_min,
                    ConnectionLog.connected_at <= dt_max,
                )
                .order_by(ConnectionLog.connected_at.desc(), ConnectionLog.id.desc())
                .limit(10000)
                .all()
            )
            for log in conn_rows:
                if log.vpn_session_id:
                    connection_logs_by_session.setdefault(log.vpn_session_id, []).append(log)

            tel_rows = (
                db.query(TelemetryEvent)
                .filter(
                    TelemetryEvent.vpn_session_id.in_(session_ids),
                    TelemetryEvent.timestamp >= dt_min,
                    TelemetryEvent.timestamp <= dt_max,
                )
                .order_by(TelemetryEvent.timestamp.desc(), TelemetryEvent.id.desc())
                .limit(10000)
                .all()
            )
            for log in tel_rows:
                if log.vpn_session_id:
                    telemetry_logs_by_session.setdefault(log.vpn_session_id, []).append(log)

        enriched_items = []
        for row, base in zip(rows, items):
            user_ctx = user_map.get(row.user_id) if row.user_id is not None else None
            device_ctx = device_map.get(row.device_id) if row.device_id is not None else None
            server_ctx = server_map.get(row.server_id) if row.server_id is not None else None
            session_id = row.vpn_session_id
            cl = _pick_nearest_log(client_logs_by_session.get(session_id, []), row.event_time, "created_at") if session_id else None
            conn = _pick_nearest_log(connection_logs_by_session.get(session_id, []), row.event_time, "connected_at") if session_id else None
            tel = _pick_nearest_log(telemetry_logs_by_session.get(session_id, []), row.event_time, "timestamp") if session_id else None

            base["user_context"] = (
                {
                    "id": user_ctx.id,
                    "email": user_ctx.email,
                    "role": user_ctx.role.value if user_ctx.role else None,
                    "is_active": user_ctx.is_active,
                    "is_verified": user_ctx.is_verified,
                    "country": user_ctx.country,
                    "last_seen_at": user_ctx.last_seen_at.isoformat() if user_ctx.last_seen_at else None,
                }
                if user_ctx
                else None
            )
            base["device_context"] = (
                {
                    "id": device_ctx.id,
                    "device_id": device_ctx.device_id,
                    "platform": device_ctx.platform,
                    "model": device_ctx.model,
                    "app_version": device_ctx.app_version,
                    "last_ip": device_ctx.last_ip,
                    "last_country": device_ctx.last_country,
                }
                if device_ctx
                else None
            )
            base["server_context"] = (
                {
                    "id": server_ctx.id,
                    "name": server_ctx.name,
                    "country": server_ctx.country,
                    "city": server_ctx.city,
                    "provider": server_ctx.provider,
                    "status": server_ctx.status,
                    "health_status": server_ctx.health_status,
                }
                if server_ctx
                else None
            )
            base["related_logs"] = {
                "client_log": (
                    {
                        "id": cl.id,
                        "created_at": cl.created_at.isoformat() if cl.created_at else None,
                        "event_type": cl.event_type,
                        "protocol": cl.protocol,
                        "error_code": cl.error_code,
                        "message": cl.message,
                        "app_version": cl.app_version,
                        "platform": cl.platform,
                    }
                    if cl
                    else None
                ),
                "vpn_server_log": (
                    {
                        "id": conn.id,
                        "connected_at": conn.connected_at.isoformat() if conn.connected_at else None,
                        "disconnected_at": conn.disconnected_at.isoformat() if conn.disconnected_at else None,
                        "connection_type": conn.connection_type,
                        "ip_address": conn.ip_address,
                        "duration_seconds": conn.duration_seconds,
                    }
                    if conn
                    else None
                ),
                "telemetry_log": (
                    {
                        "id": tel.id,
                        "timestamp": tel.timestamp.isoformat() if tel.timestamp else None,
                        "event_type": tel.event_type,
                        "error_code": tel.error_code,
                        "error_message": tel.error_message,
                        "network_type": tel.network_type,
                        "app_version": tel.app_version,
                        "platform": tel.platform,
                    }
                    if tel
                    else None
                ),
            }
            enriched_items.append(base)
        items = enriched_items

    next_cursor = _build_events_cursor("events_keyset", rows[-1]) if (has_more and rows) else None
    prev_cursor = _build_events_cursor("events_keyset_prev", rows[0]) if rows else None
    return {
        "items": items,
        "next_cursor": next_cursor,
        "prev_cursor": prev_cursor,
        "detail_level": detail_level,
        "analytics_backend": effective_backend,
        "analytics_backend_configured": configured_backend,
    }


@router.get("/config-trace")
async def get_config_trace_by_request_id(
    request_id: str,
    limit: int = 50,
    admin_user: User = Depends(get_current_admin_user),
    db: Session = Depends(get_db),
):
    _ = admin_user
    req_id = (request_id or "").strip()
    if not req_id:
        raise HTTPException(status_code=400, detail="request_id is required")
    limit = max(1, min(limit, 200))

    rows = (
        db.query(ObservabilityEvent)
        .filter(ObservabilityEvent.request_id == req_id)
        .order_by(ObservabilityEvent.event_time.desc(), ObservabilityEvent.id.desc())
        .limit(limit)
        .all()
    )

    items = []
    summary = {
        "request_id": req_id,
        "event_count": len(rows),
        "matches": 0,
        "mismatches": 0,
        "unknown": 0,
    }
    for row in rows:
        expected = _as_hash_text(row.config_hash_expected or row.config_revision)
        actual = _as_hash_text(row.config_hash_actual)
        if expected and actual:
            status = "match" if expected == actual else "mismatch"
        else:
            status = "unknown"
        if status == "match":
            summary["matches"] += 1
        elif status == "mismatch":
            summary["mismatches"] += 1
        else:
            summary["unknown"] += 1

        attrs = row.attrs_json or {}
        items.append(
            {
                "id": row.id,
                "event_time": row.event_time.isoformat() if row.event_time else None,
                "event_name": row.event_name,
                "severity": row.severity,
                "protocol": row.protocol,
                "stage": row.stage,
                "outcome": row.outcome,
                "reason_code": row.reason_code,
                "config_revision": row.config_revision,
                "payload_fingerprint": attrs.get("payload_fingerprint") or expected,
                "active_config_hash": attrs.get("active_config_hash") or actual,
                "comparison_status": status,
                "attrs": attrs,
            }
        )

    return {"summary": summary, "items": items}


@router.get("/session-diagnostics")
async def get_session_diagnostics(
    vpn_session_id: str,
    window_seconds: int = 600,
    create_incident: bool = False,
    admin_user: User = Depends(get_current_admin_user),
    db: Session = Depends(get_db),
):
    _ = admin_user
    session_id = (vpn_session_id or "").strip()
    if not session_id:
        raise HTTPException(status_code=400, detail="vpn_session_id is required")
    window_seconds = max(60, min(window_seconds, 7200))

    latest_event = (
        db.query(ObservabilityEvent)
        .filter(ObservabilityEvent.vpn_session_id == session_id)
        .order_by(ObservabilityEvent.event_time.desc(), ObservabilityEvent.id.desc())
        .first()
    )
    latest_client_log = (
        db.query(ClientLog)
        .filter(ClientLog.vpn_session_id == session_id)
        .order_by(ClientLog.created_at.desc(), ClientLog.id.desc())
        .first()
    )
    anchor_time = None
    if latest_event and latest_event.event_time:
        anchor_time = latest_event.event_time
    if latest_client_log and latest_client_log.created_at:
        if anchor_time is None or latest_client_log.created_at > anchor_time:
            anchor_time = latest_client_log.created_at
    if anchor_time is None:
        raise HTTPException(status_code=404, detail="session not found")

    dt_from = anchor_time - timedelta(seconds=window_seconds)
    dt_to = anchor_time + timedelta(seconds=window_seconds)
    event_rows = (
        db.query(ObservabilityEvent)
        .filter(
            ObservabilityEvent.vpn_session_id == session_id,
            ObservabilityEvent.event_time >= dt_from,
            ObservabilityEvent.event_time <= dt_to,
        )
        .order_by(ObservabilityEvent.event_time.asc(), ObservabilityEvent.id.asc())
        .limit(1000)
        .all()
    )
    client_rows = (
        db.query(ClientLog)
        .filter(
            ClientLog.vpn_session_id == session_id,
            ClientLog.created_at >= dt_from,
            ClientLog.created_at <= dt_to,
        )
        .order_by(ClientLog.created_at.asc(), ClientLog.id.asc())
        .limit(1000)
        .all()
    )
    connection_rows = (
        db.query(ConnectionLog)
        .filter(
            ConnectionLog.vpn_session_id == session_id,
            ConnectionLog.connected_at >= dt_from,
            ConnectionLog.connected_at <= dt_to,
        )
        .order_by(ConnectionLog.connected_at.asc(), ConnectionLog.id.asc())
        .limit(200)
        .all()
    )
    classification = _classify_session_failure(client_logs=client_rows, events=event_rows)
    incident_payload = None
    if create_incident and classification.get("confidence") in {"high", "medium"}:
        incident = _upsert_session_diagnostic_incident(
            db,
            vpn_session_id=session_id,
            classification=classification,
            event_rows=event_rows,
            client_rows=client_rows,
        )
        db.commit()
        incident_payload = {
            "id": incident.id,
            "incident_key": incident.incident_key,
            "status": incident.status,
            "severity": incident.severity,
            "incident_type": incident.incident_type,
        }

    return {
        "vpn_session_id": session_id,
        "window_seconds": window_seconds,
        "diagnostic": classification,
        "incident": incident_payload,
        "counters": {
            "observability_events": len(event_rows),
            "client_logs": len(client_rows),
            "connection_logs": len(connection_rows),
        },
        "timeline": {
            "events": [
                {
                    "id": row.id,
                    "event_time": row.event_time.isoformat() if row.event_time else None,
                    "event_name": row.event_name,
                    "stage": row.stage,
                    "outcome": row.outcome,
                    "reason_code": row.reason_code,
                    "message": row.message,
                }
                for row in event_rows
            ],
            "client_logs": [
                {
                    "id": row.id,
                    "created_at": row.created_at.isoformat() if row.created_at else None,
                    "event_type": row.event_type,
                    "message": row.message,
                    "error_code": row.error_code,
                    "error_details": row.error_details or {},
                }
                for row in client_rows
            ],
        },
    }


@router.get("/users/{user_id}/journey")
async def get_user_journey(
    user_id: int,
    from_time: Optional[str] = None,
    to_time: Optional[str] = None,
    server_id: Optional[int] = None,
    include_raw: bool = False,
    admin_user: User = Depends(get_current_admin_user),
    db: Session = Depends(get_db),
):
    _ = admin_user
    dt_from = _parse_dt(from_time)
    dt_to = _parse_dt(to_time)
    query = db.query(ObservabilityEvent).filter(ObservabilityEvent.user_id == user_id)
    if dt_from:
        query = query.filter(ObservabilityEvent.event_time >= dt_from)
    if dt_to:
        query = query.filter(ObservabilityEvent.event_time <= dt_to)
    if server_id:
        query = query.filter(ObservabilityEvent.server_id == server_id)
    rows = query.order_by(ObservabilityEvent.event_time.desc()).limit(1000).all()

    grouped: dict[str, list[dict]] = {}
    for row in rows:
        key = row.vpn_session_id or "no_session"
        grouped.setdefault(key, []).append(
            {
                "event_time": row.event_time.isoformat() if row.event_time else None,
                "event_name": row.event_name,
                "severity": row.severity,
                "server_id": row.server_id,
                "protocol": row.protocol,
                "message": row.message,
                "reason_code": row.reason_code,
                "raw_attrs": row.attrs_json if include_raw else None,
            }
        )
    return {"user_id": user_id, "sessions": grouped, "count": len(rows)}


@router.get("/servers/{server_id}/conflicts")
async def get_server_conflicts(
    server_id: int,
    include_resolved: bool = False,
    admin_user: User = Depends(get_current_admin_user),
    db: Session = Depends(get_db),
):
    _ = admin_user
    query = db.query(ObservabilityIncident).filter(
        ObservabilityIncident.incident_type.in_(
            ["duplicate_session", "stale_tunnel", "config_conflict"]
        )
    )
    if not include_resolved:
        query = query.filter(ObservabilityIncident.status != "resolved")
    rows = query.order_by(ObservabilityIncident.last_seen_at.desc()).limit(200).all()
    items = []
    for row in rows:
        evidence = row.evidence_json or {}
        if evidence.get("server_id") not in (None, server_id):
            continue
        items.append(
            {
                "id": row.id,
                "incident_type": row.incident_type,
                "severity": row.severity,
                "status": row.status,
                "title": row.title,
                "summary": row.summary,
                "evidence": evidence,
                "first_seen_at": row.first_seen_at.isoformat() if row.first_seen_at else None,
                "last_seen_at": row.last_seen_at.isoformat() if row.last_seen_at else None,
            }
        )
    return {"server_id": server_id, "conflicts": items, "count": len(items)}


@router.get("/incidents")
async def get_incidents(
    status: Optional[str] = None,
    severity: Optional[str] = None,
    incident_type: Optional[str] = None,
    from_time: Optional[str] = None,
    to_time: Optional[str] = None,
    assignee_user_id: Optional[int] = None,
    server_id: Optional[int] = None,
    limit: int = 200,
    cursor: Optional[str] = None,
    breached_only: bool = False,
    cursor_direction: str = "next",
    sort_by: str = "last_seen_at",
    sort_dir: str = "desc",
    admin_user: User = Depends(get_current_admin_user),
    db: Session = Depends(get_db),
):
    _ = admin_user
    limit = max(1, min(limit, 1000))
    cursor_data = _decode_cursor(cursor)
    dt_from = _parse_dt(from_time)
    dt_to = _parse_dt(to_time)
    query = db.query(ObservabilityIncident)
    if status:
        query = query.filter(ObservabilityIncident.status == status)
    if severity:
        query = query.filter(ObservabilityIncident.severity == severity)
    if incident_type:
        query = query.filter(ObservabilityIncident.incident_type == incident_type)
    if dt_from:
        query = query.filter(ObservabilityIncident.last_seen_at >= dt_from)
    if dt_to:
        query = query.filter(ObservabilityIncident.last_seen_at <= dt_to)
    if assignee_user_id is not None:
        query = query.filter(ObservabilityIncident.assignee_user_id == assignee_user_id)
    if server_id is not None:
        query = query.filter(ObservabilityIncident.evidence_json["server_id"].astext == str(server_id))
    if breached_only:
        now = datetime.utcnow()
        cond = (
            (ObservabilityIncident.status != "resolved")
            & (
                ((ObservabilityIncident.severity == "P1") & (ObservabilityIncident.first_seen_at < (now - timedelta(minutes=_SLA_TARGETS["P1"]))))
                | ((ObservabilityIncident.severity == "P2") & (ObservabilityIncident.first_seen_at < (now - timedelta(minutes=_SLA_TARGETS["P2"]))))
                | ((ObservabilityIncident.severity == "P3") & (ObservabilityIncident.first_seen_at < (now - timedelta(minutes=_SLA_TARGETS["P3"]))))
                | ((ObservabilityIncident.severity == "P4") & (ObservabilityIncident.first_seen_at < (now - timedelta(minutes=_SLA_TARGETS["P4"]))))
            )
        )
        query = query.filter(cond)

    sort_fields = {
        "last_seen_at": ObservabilityIncident.last_seen_at,
        "first_seen_at": ObservabilityIncident.first_seen_at,
        "severity": ObservabilityIncident.severity,
        "status": ObservabilityIncident.status,
        "id": ObservabilityIncident.id,
    }
    order_col = sort_fields.get(sort_by, ObservabilityIncident.last_seen_at)
    if (sort_dir or "").lower() == "asc":
        query = query.order_by(order_col.asc())
    else:
        query = query.order_by(order_col.desc())

    keyset_supported = sort_by == "last_seen_at" and (sort_dir or "").lower() in ("desc", "asc")
    if keyset_supported and cursor_data and cursor_data.get("mode") in ("incidents_keyset", "incidents_keyset_prev"):
        cur_time = _parse_dt(cursor_data.get("t"))
        cur_id = cursor_data.get("id")
        cur_dir = cursor_data.get("dir", "desc")
        if cur_time and isinstance(cur_id, int):
            if cursor_direction == "prev":
                if cur_dir == "asc":
                    query = query.filter(
                        or_(
                            ObservabilityIncident.last_seen_at < cur_time,
                            and_(
                                ObservabilityIncident.last_seen_at == cur_time,
                                ObservabilityIncident.id < cur_id,
                            ),
                        )
                    )
                    rows = query.order_by(ObservabilityIncident.last_seen_at.desc(), ObservabilityIncident.id.desc()).limit(limit + 1).all()
                else:
                    query = query.filter(
                        or_(
                            ObservabilityIncident.last_seen_at > cur_time,
                            and_(
                                ObservabilityIncident.last_seen_at == cur_time,
                                ObservabilityIncident.id > cur_id,
                            ),
                        )
                    )
                    rows = query.order_by(ObservabilityIncident.last_seen_at.asc(), ObservabilityIncident.id.asc()).limit(limit + 1).all()
                has_more = len(rows) > limit
                rows = rows[:limit]
                rows.reverse()
            else:
                if cur_dir == "asc":
                    query = query.filter(
                        or_(
                            ObservabilityIncident.last_seen_at > cur_time,
                            and_(
                                ObservabilityIncident.last_seen_at == cur_time,
                                ObservabilityIncident.id > cur_id,
                            ),
                        )
                    )
                else:
                    query = query.filter(
                        or_(
                            ObservabilityIncident.last_seen_at < cur_time,
                            and_(
                                ObservabilityIncident.last_seen_at == cur_time,
                                ObservabilityIncident.id < cur_id,
                            ),
                        )
                    )
                rows = query.limit(limit + 1).all()
                has_more = len(rows) > limit
                rows = rows[:limit]
        else:
            rows = query.limit(limit + 1).all()
            has_more = len(rows) > limit
            rows = rows[:limit]
    elif keyset_supported:
        rows = query.limit(limit + 1).all()
        has_more = len(rows) > limit
        rows = rows[:limit]
    else:
        offset = int(cursor_data.get("offset", 0)) if cursor_data else 0
        rows = query.offset(max(0, offset)).limit(limit + 1).all()
        has_more = len(rows) > limit
        rows = rows[:limit]
    if has_more and rows:
        last = rows[-1]
        if keyset_supported:
            next_cursor = _encode_cursor(
                {
                    "mode": "incidents_keyset",
                    "t": last.last_seen_at.isoformat() if last.last_seen_at else None,
                    "id": last.id,
                    "dir": (sort_dir or "desc").lower(),
                }
            )
        else:
            next_cursor = _encode_cursor(
                {
                    "mode": "incidents_offset",
                    "offset": (int(cursor_data.get("offset", 0)) if cursor_data else 0) + limit,
                }
            )
    else:
        next_cursor = None
    prev_cursor = None
    if rows:
        if keyset_supported:
            prev_cursor = _build_incidents_cursor(
                "incidents_keyset_prev",
                rows[0],
                (sort_dir or "desc").lower(),
            )
        else:
            offset = int(cursor_data.get("offset", 0)) if cursor_data else 0
            prev_cursor = _encode_cursor({"mode": "incidents_offset", "offset": max(0, offset - limit)})
    return {
        "items": [
            {
                "id": row.id,
                "incident_key": row.incident_key,
                "incident_type": row.incident_type,
                "severity": row.severity,
                "status": row.status,
                "title": row.title,
                "summary": row.summary,
                "evidence": row.evidence_json or {},
                "assignee_user_id": row.assignee_user_id,
                "sla": _incident_sla_payload(row),
                "first_seen_at": row.first_seen_at.isoformat() if row.first_seen_at else None,
                "last_seen_at": row.last_seen_at.isoformat() if row.last_seen_at else None,
            }
            for row in rows
        ],
        "next_cursor": next_cursor,
        "prev_cursor": prev_cursor,
    }


@router.get("/incidents/{incident_id}")
async def get_incident_detail(
    incident_id: int,
    admin_user: User = Depends(get_current_admin_user),
    db: Session = Depends(get_db),
):
    _ = admin_user
    incident = db.query(ObservabilityIncident).filter(ObservabilityIncident.id == incident_id).first()
    if not incident:
        raise HTTPException(status_code=404, detail="Incident not found")
    comments = (
        db.query(ObservabilityIncidentComment)
        .filter(ObservabilityIncidentComment.incident_id == incident_id)
        .order_by(ObservabilityIncidentComment.created_at.desc())
        .all()
    )
    evidence = incident.evidence_json or {}
    related_filters = {
        "vpn_session_id": evidence.get("vpn_session_id"),
        "request_id": evidence.get("request_id"),
        "server_id": evidence.get("server_id"),
    }
    related_query = db.query(ObservabilityEvent)
    if related_filters["vpn_session_id"]:
        related_query = related_query.filter(ObservabilityEvent.vpn_session_id == related_filters["vpn_session_id"])
    elif related_filters["request_id"]:
        related_query = related_query.filter(ObservabilityEvent.request_id == related_filters["request_id"])
    elif related_filters["server_id"] is not None:
        related_query = related_query.filter(ObservabilityEvent.server_id == related_filters["server_id"])
    else:
        related_query = related_query.filter(
            ObservabilityEvent.event_time >= (incident.first_seen_at or datetime.utcnow()) - timedelta(minutes=10),
            ObservabilityEvent.event_time <= (incident.last_seen_at or datetime.utcnow()) + timedelta(minutes=10),
        )
    related_events = related_query.order_by(ObservabilityEvent.event_time.desc()).limit(30).all()
    return {
        "incident": {
            "id": incident.id,
            "incident_key": incident.incident_key,
            "incident_type": incident.incident_type,
            "severity": incident.severity,
            "status": incident.status,
            "title": incident.title,
            "summary": incident.summary,
            "evidence": evidence,
            "assignee_user_id": incident.assignee_user_id,
            "sla": _incident_sla_payload(incident),
            "first_seen_at": incident.first_seen_at.isoformat() if incident.first_seen_at else None,
            "last_seen_at": incident.last_seen_at.isoformat() if incident.last_seen_at else None,
            "resolved_at": incident.resolved_at.isoformat() if incident.resolved_at else None,
        },
        "related_filters": related_filters,
        "related_events": [
            {
                "id": ev.id,
                "event_time": ev.event_time.isoformat() if ev.event_time else None,
                "event_name": ev.event_name,
                "severity": ev.severity,
                "vpn_session_id": ev.vpn_session_id,
                "request_id": ev.request_id,
                "server_id": ev.server_id,
                "message": ev.message,
            }
            for ev in related_events
        ],
        "comments": [
            {
                "id": row.id,
                "incident_id": row.incident_id,
                "author_user_id": row.author_user_id,
                "comment": row.comment,
                "created_at": row.created_at.isoformat() if row.created_at else None,
            }
            for row in comments
        ],
    }


@router.get("/metrics/incidents")
async def get_incident_metrics(
    from_time: Optional[str] = None,
    to_time: Optional[str] = None,
    admin_user: User = Depends(get_current_admin_user),
    db: Session = Depends(get_db),
):
    _ = admin_user
    dt_from = _parse_dt(from_time)
    dt_to = _parse_dt(to_time)
    query = db.query(ObservabilityIncident)
    if dt_from:
        query = query.filter(ObservabilityIncident.last_seen_at >= dt_from)
    if dt_to:
        query = query.filter(ObservabilityIncident.last_seen_at <= dt_to)

    open_total = query.filter(ObservabilityIncident.status != "resolved").count()

    by_severity_rows = (
        query.with_entities(ObservabilityIncident.severity, func.count(ObservabilityIncident.id))
        .group_by(ObservabilityIncident.severity)
        .all()
    )
    by_status_rows = (
        query.with_entities(ObservabilityIncident.status, func.count(ObservabilityIncident.id))
        .group_by(ObservabilityIncident.status)
        .all()
    )
    return {
        "open_total": open_total,
        "by_severity": {k or "unknown": v for k, v in by_severity_rows},
        "by_status": {k or "unknown": v for k, v in by_status_rows},
    }


class IncidentStatusBody(BaseModel):
    status: str


class IncidentAssignBody(BaseModel):
    assignee_user_id: Optional[int] = None


class IncidentCommentBody(BaseModel):
    comment: str


@router.post("/incidents/{incident_id}/status")
async def update_incident_status(
    incident_id: int,
    body: IncidentStatusBody,
    admin_user: User = Depends(get_current_admin_user),
    db: Session = Depends(get_db),
):
    _ = admin_user
    incident = db.query(ObservabilityIncident).filter(ObservabilityIncident.id == incident_id).first()
    if not incident:
        raise HTTPException(status_code=404, detail="Incident not found")
    incident.status = body.status
    if body.status == "resolved":
        incident.resolved_at = datetime.utcnow()
    db.commit()
    return {"ok": True, "incident_id": incident_id, "status": incident.status}


@router.post("/incidents/{incident_id}/assign")
async def assign_incident(
    incident_id: int,
    body: IncidentAssignBody,
    admin_user: User = Depends(get_current_admin_user),
    db: Session = Depends(get_db),
):
    _ = admin_user
    incident = db.query(ObservabilityIncident).filter(ObservabilityIncident.id == incident_id).first()
    if not incident:
        raise HTTPException(status_code=404, detail="Incident not found")
    incident.assignee_user_id = body.assignee_user_id
    db.commit()
    return {"ok": True, "incident_id": incident_id, "assignee_user_id": incident.assignee_user_id}


@router.post("/incidents/{incident_id}/comment")
async def add_incident_comment(
    incident_id: int,
    body: IncidentCommentBody,
    admin_user: User = Depends(get_current_admin_user),
    db: Session = Depends(get_db),
):
    incident = db.query(ObservabilityIncident).filter(ObservabilityIncident.id == incident_id).first()
    if not incident:
        raise HTTPException(status_code=404, detail="Incident not found")
    comment_text = (body.comment or "").strip()
    if not comment_text:
        raise HTTPException(status_code=400, detail="Comment is required")
    row = ObservabilityIncidentComment(
        incident_id=incident.id,
        author_user_id=admin_user.id if getattr(admin_user, "id", None) else None,
        comment=comment_text,
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    return {
        "ok": True,
        "comment_id": row.id,
        "incident_id": incident_id,
        "created_at": row.created_at.isoformat() if row.created_at else None,
    }


@router.get("/dictionary/events")
async def get_dictionary_events(
    admin_user: User = Depends(get_current_admin_user),
    db: Session = Depends(get_db),
):
    _ = admin_user
    rows = db.query(EventDictionary).order_by(EventDictionary.event_name.asc()).all()
    return {
        "items": [
            {
                "event_name": row.event_name,
                "display_name_ru": row.display_name_ru,
                "display_name_en": row.display_name_en,
                "default_comment_template": row.default_comment_template,
                "operator_hint": row.operator_hint,
                "severity_default": row.severity_default,
                "is_active": row.is_active,
            }
            for row in rows
        ]
    }


class EventDictionaryUpsertBody(BaseModel):
    display_name_ru: str
    display_name_en: str
    default_comment_template: Optional[str] = None
    operator_hint: Optional[str] = None
    severity_default: str = "info"
    is_active: bool = True


@router.put("/dictionary/events/{event_name}")
async def upsert_dictionary_event(
    event_name: str,
    body: EventDictionaryUpsertBody,
    admin_user: User = Depends(get_current_admin_user),
    db: Session = Depends(get_db),
):
    _ = admin_user
    row = db.query(EventDictionary).filter(EventDictionary.event_name == event_name).first()
    if row is None:
        row = EventDictionary(
            event_name=event_name,
            display_name_ru=body.display_name_ru,
            display_name_en=body.display_name_en,
            default_comment_template=body.default_comment_template,
            operator_hint=body.operator_hint,
            severity_default=body.severity_default,
            is_active=body.is_active,
        )
        db.add(row)
    else:
        row.display_name_ru = body.display_name_ru
        row.display_name_en = body.display_name_en
        row.default_comment_template = body.default_comment_template
        row.operator_hint = body.operator_hint
        row.severity_default = body.severity_default
        row.is_active = body.is_active
    db.commit()
    return {"ok": True, "event_name": event_name}


class GenerateTestIncidentBody(BaseModel):
    incident_type: str = "config_conflict"
    severity: str = "P2"
    user_id: Optional[int] = None
    server_id: Optional[int] = None
    vpn_session_id: Optional[str] = None
    request_id: Optional[str] = None
    message: Optional[str] = None


@router.post("/testing/generate")
async def generate_test_incident_event(
    body: GenerateTestIncidentBody,
    admin_user: User = Depends(get_current_admin_user),
    db: Session = Depends(get_db),
):
    _ = admin_user
    if settings.is_production:
        raise HTTPException(status_code=403, detail="Disabled in production")
    now = datetime.utcnow()
    event_name = "VPN_CONFIG_CONFLICT_DETECTED"
    if body.incident_type == "duplicate_session":
        event_name = "VPN_SESSION_DUPLICATE_DETECTED"
    elif body.incident_type == "stale_tunnel":
        event_name = "VPN_SESSION_STALE_DETECTED"
    event = ObservabilityEvent(
        event_time=now,
        event_name=event_name,
        severity="warn" if body.severity in ("P3", "P4") else "error",
        source="admin_panel",
        user_id=body.user_id,
        server_id=body.server_id,
        vpn_session_id=body.vpn_session_id,
        request_id=body.request_id,
        reason_code=f"TEST_{body.incident_type.upper()}",
        message=body.message or "Generated test event from admin observability",
        attrs_json={"test": True, "generated_by_user_id": getattr(admin_user, "id", None)},
        schema_version=1,
    )
    db.add(event)
    incident = ObservabilityIncident(
        incident_key=f"test:{body.incident_type}:{int(now.timestamp())}",
        incident_type=body.incident_type,
        severity=body.severity,
        status="open",
        title=f"Test incident: {body.incident_type}",
        summary=body.message or "Generated from testing endpoint",
        evidence_json={
            "test": True,
            "vpn_session_id": body.vpn_session_id,
            "request_id": body.request_id,
            "server_id": body.server_id,
            "user_id": body.user_id,
        },
        first_seen_at=now,
        last_seen_at=now,
    )
    db.add(incident)
    db.commit()
    db.refresh(event)
    db.refresh(incident)
    return {"ok": True, "event_id": event.id, "incident_id": incident.id}

import logging
from datetime import datetime, timedelta

from sqlalchemy import and_

from core.database import SessionLocal
from core.metrics import metrics_registry
from models.observability import ObservabilityEvent, ObservabilityIncident
from models.system_setting import SystemSetting
from services.celery_app import celery_app

logger = logging.getLogger(__name__)


def _get_setting(db, key: str, default):
    row = db.query(SystemSetting).filter(SystemSetting.key == key).first()
    if row is None:
        return default
    return row.value if row.value is not None else default


def _set_setting(db, key: str, value):
    row = db.query(SystemSetting).filter(SystemSetting.key == key).first()
    if row is None:
        row = SystemSetting(key=key, value=value)
        db.add(row)
    else:
        row.value = value
    return row


def _upsert_incident(
    db,
    *,
    incident_key: str,
    incident_type: str,
    severity: str,
    title: str,
    summary: str,
    evidence: dict,
) -> ObservabilityIncident:
    now = datetime.utcnow()
    row = (
        db.query(ObservabilityIncident)
        .filter(
            ObservabilityIncident.incident_key == incident_key,
            ObservabilityIncident.status.in_(["open", "investigating", "mitigated"]),
        )
        .order_by(ObservabilityIncident.id.desc())
        .first()
    )
    if row is None:
        row = ObservabilityIncident(
            incident_key=incident_key,
            incident_type=incident_type,
            severity=severity,
            status="open",
            title=title,
            summary=summary,
            evidence_json=evidence,
            first_seen_at=now,
            last_seen_at=now,
        )
        db.add(row)
    else:
        row.last_seen_at = now
        row.severity = severity
        row.title = title
        row.summary = summary
        row.evidence_json = evidence
    return row


@celery_app.task(bind=True, name="observability.detect_incidents")
def detect_observability_incidents_task(self):
    """
    Minimal rule engine:
    - duplicate_session
    - stale_tunnel
    - config_conflict
    """
    db = SessionLocal()
    try:
        now = datetime.utcnow()
        window_15 = now - timedelta(minutes=15)
        window_30 = now - timedelta(minutes=30)
        created_or_updated = 0

        # Rule 1: duplicate sessions for same user+device_fingerprint
        dup_events = (
            db.query(ObservabilityEvent)
            .filter(
                ObservabilityEvent.event_name == "VPN_TUNNEL_ESTABLISHED",
                ObservabilityEvent.event_time >= window_15,
                ObservabilityEvent.user_id.isnot(None),
                ObservabilityEvent.device_fingerprint.isnot(None),
            )
            .all()
        )
        counter = {}
        for e in dup_events:
            key = (e.user_id, e.device_fingerprint)
            counter[key] = counter.get(key, 0) + 1
        for (user_id, device_fingerprint), count in counter.items():
            if count < 2:
                continue
            incident = _upsert_incident(
                db,
                incident_key=f"duplicate_session:user:{user_id}:fp:{device_fingerprint}",
                incident_type="duplicate_session",
                severity="P3",
                title="Duplicate VPN sessions detected",
                summary=f"Multiple tunnel establish events for user={user_id}",
                evidence={
                    "user_id": user_id,
                    "device_fingerprint": device_fingerprint,
                    "count": count,
                    "window_minutes": 15,
                },
            )
            created_or_updated += 1
            logger.warning("duplicate_session incident id=%s user_id=%s count=%s", incident.id, user_id, count)

        # Rule 2: stale tunnel established but no close event in last 30 min
        established = (
            db.query(ObservabilityEvent)
            .filter(
                ObservabilityEvent.event_name == "VPN_TUNNEL_ESTABLISHED",
                ObservabilityEvent.event_time >= window_30,
                ObservabilityEvent.vpn_session_id.isnot(None),
            )
            .all()
        )
        for e in established:
            closed = (
                db.query(ObservabilityEvent.id)
                .filter(
                    ObservabilityEvent.event_name == "VPN_TUNNEL_CLOSED",
                    ObservabilityEvent.vpn_session_id == e.vpn_session_id,
                    ObservabilityEvent.event_time >= e.event_time,
                )
                .first()
            )
            if closed:
                continue
            incident = _upsert_incident(
                db,
                incident_key=f"stale_tunnel:session:{e.vpn_session_id}",
                incident_type="stale_tunnel",
                severity="P3",
                title="Stale VPN tunnel",
                summary=f"No close event for vpn_session_id={e.vpn_session_id}",
                evidence={
                    "vpn_session_id": e.vpn_session_id,
                    "user_id": e.user_id,
                    "server_id": e.server_id,
                    "established_at": e.event_time.isoformat() if e.event_time else None,
                },
            )
            created_or_updated += 1

        # Rule 3: config conflicts via explicit events
        conflicts = (
            db.query(ObservabilityEvent)
            .filter(
                ObservabilityEvent.event_name.in_(
                    ["VPN_CONFIG_CONFLICT_DETECTED", "VPN_CONFIG_REVISION_MISMATCH"]
                ),
                ObservabilityEvent.event_time >= window_30,
            )
            .all()
        )
        for e in conflicts:
            scope_server = e.server_id or 0
            incident = _upsert_incident(
                db,
                incident_key=f"config_conflict:server:{scope_server}",
                incident_type="config_conflict",
                severity="P2",
                title="VPN config conflict detected",
                summary="Detected config revision/hash mismatch",
                evidence={
                    "server_id": e.server_id,
                    "vpn_session_id": e.vpn_session_id,
                    "event_name": e.event_name,
                    "reason_code": e.reason_code,
                    "config_revision": e.config_revision,
                    "config_hash_expected": e.config_hash_expected,
                    "config_hash_actual": e.config_hash_actual,
                },
            )
            created_or_updated += 1
            logger.warning("config_conflict incident id=%s server_id=%s", incident.id, e.server_id)

        # Auto-resolve stale open incidents if no evidence in 30 min
        cutoff = now - timedelta(minutes=30)
        open_rows = (
            db.query(ObservabilityIncident)
            .filter(
                ObservabilityIncident.status.in_(["open", "investigating", "mitigated"]),
                ObservabilityIncident.last_seen_at < cutoff,
            )
            .all()
        )
        for row in open_rows:
            row.status = "resolved"
            row.resolved_at = now

        db.commit()
        return {
            "status": "success",
            "created_or_updated": created_or_updated,
            "auto_resolved": len(open_rows),
            "timestamp": now.isoformat(),
        }
    except Exception as exc:
        db.rollback()
        logger.exception("detect_observability_incidents failed: %s", exc)
        return {"status": "error", "error": str(exc)}
    finally:
        db.close()


@celery_app.task(bind=True, name="observability.evaluate_rollout_policy")
def evaluate_rollout_policy_task(self):
    db = SessionLocal()
    try:
        from api.admin_settings import (
            DEFAULT_ROLLOUT_POLICY,
            SETTINGS_FEATURE_FLAGS_KEY,
            SETTINGS_ROLLOUT_POLICY_KEY,
            SETTINGS_ROLLOUT_STATE_KEY,
            _is_promotion_eligible,
            _normalize_rollout_policy,
            _next_promotion_percent,
            _should_auto_rollback,
        )

        policy = _normalize_rollout_policy(
            _get_setting(db, SETTINGS_ROLLOUT_POLICY_KEY, DEFAULT_ROLLOUT_POLICY)
        )
        snap = metrics_registry.snapshot().get("vpn_connectivity", {})
        sli = snap.get("sli") or {}
        connected_local_total = int(snap.get("connected_local_total") or 0)
        decision = _should_auto_rollback(
            policy=policy, sli=sli, connected_local_total=connected_local_total
        )
        result = {
            "rollback_applied": False,
            "promotion_applied": False,
            "reasons": decision.get("reasons", []),
            "target_percent": int(policy.get("current_percent", 100)),
        }

        if decision.get("rollback"):
            rollback_percent = int(policy.get("rollback_percent", 10))
            ff = _get_setting(db, SETTINGS_FEATURE_FLAGS_KEY, {})
            if not isinstance(ff, dict):
                ff = {}
            ff["connect_flow_canary_percent"] = rollback_percent
            _set_setting(db, SETTINGS_FEATURE_FLAGS_KEY, ff)
            policy["current_percent"] = rollback_percent
            _set_setting(db, SETTINGS_ROLLOUT_POLICY_KEY, policy)
            result["rollback_applied"] = True
            result["target_percent"] = rollback_percent
        elif policy.get("enabled") and policy.get("auto_promotion_enabled", True):
            promo = _is_promotion_eligible(
                policy=policy, sli=sli, connected_local_total=connected_local_total
            )
            next_percent = _next_promotion_percent(policy)
            if (
                promo.get("eligible")
                and next_percent is not None
                and next_percent != int(policy.get("current_percent", 100))
            ):
                ff = _get_setting(db, SETTINGS_FEATURE_FLAGS_KEY, {})
                if not isinstance(ff, dict):
                    ff = {}
                ff["connect_flow_canary_percent"] = next_percent
                _set_setting(db, SETTINGS_FEATURE_FLAGS_KEY, ff)
                policy["current_percent"] = next_percent
                _set_setting(db, SETTINGS_ROLLOUT_POLICY_KEY, policy)
                result["promotion_applied"] = True
                result["target_percent"] = next_percent
                result["reasons"] = promo.get("reasons", ["healthy_sli_promote"])

        state = _get_setting(db, SETTINGS_ROLLOUT_STATE_KEY, {})
        if not isinstance(state, dict):
            state = {}
        state.update(
            {
                "last_evaluated_at": datetime.utcnow().isoformat() + "Z",
                "last_reasons": result["reasons"],
                "last_rollback_applied": result["rollback_applied"],
                "last_promotion_applied": result["promotion_applied"],
                "last_target_percent": result["target_percent"],
                "last_source": "celery",
            }
        )
        _set_setting(db, SETTINGS_ROLLOUT_STATE_KEY, state)
        db.commit()
        return {"status": "success", "decision": result, "connected_local_total": connected_local_total}
    except Exception as exc:
        db.rollback()
        logger.exception("evaluate_rollout_policy_task failed: %s", exc)
        return {"status": "error", "error": str(exc)}
    finally:
        db.close()

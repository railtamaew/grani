from core.observability_incidents import (
    classify_root_cause_from_client_log,
    upsert_session_connectivity_incident,
)
from models.observability import ObservabilityIncident


def test_classify_root_cause_from_client_log_public_timeout():
    root_cause = classify_root_cause_from_client_log(
        event_type="connection_error",
        message="connectivity_commit_failed",
        error_details={"public_ok": False, "api_ok": True},
    )
    assert root_cause == "data_plane_egress_timeout_public_only"


def test_upsert_session_connectivity_incident_deduplicates(db_session):
    upsert_session_connectivity_incident(
        db_session,
        vpn_session_id="sess-ingest-1",
        root_cause="data_plane_degraded_commit_gate",
        user_id=1,
        server_id=1,
        device_id=1,
        protocol="xray_vless",
        evidence={"event_type": "connection_error"},
    )
    db_session.commit()
    upsert_session_connectivity_incident(
        db_session,
        vpn_session_id="sess-ingest-1",
        root_cause="data_plane_degraded_commit_gate",
        user_id=1,
        server_id=1,
        device_id=1,
        protocol="xray_vless",
        evidence={"event_type": "connection_error"},
    )
    db_session.commit()

    rows = (
        db_session.query(ObservabilityIncident)
        .filter(ObservabilityIncident.incident_key == "session_diag:sess-ingest-1:data_plane_degraded_commit_gate")
        .all()
    )
    assert len(rows) == 1

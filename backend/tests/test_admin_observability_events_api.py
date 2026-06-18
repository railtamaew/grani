"""
Контрактные тесты /api/admin/observability/events.
"""
from datetime import datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from core.database import get_db
from models.client_log import ClientLog
from models.observability import ObservabilityEvent, ObservabilityIncident
from models.server import ConnectionLog, Server
from models.telemetry import TelemetryEvent
from models.user import Device, User, UserRole
from services.auth_service import AuthService


@pytest.fixture
def admin_user(db_session):
    user = User(
        email="obs-owner@test.local",
        password_hash=AuthService.hash_password("OwnerPass123"),
        is_active=True,
        is_verified=True,
        role=UserRole.OWNER,
        auth_provider="email",
    )
    db_session.add(user)
    db_session.commit()
    db_session.refresh(user)
    return user


@pytest.fixture
def admin_token(admin_user):
    return AuthService.create_access_token(admin_user.id)


@pytest.fixture
def client(db_session):
    from main import app

    def override_get_db():
        yield db_session

    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as c:
        yield c
    app.dependency_overrides.pop(get_db, None)


@pytest.fixture
def seed_obs_data(db_session, admin_user):
    server = Server(
        name="HU-BUD-01",
        country="HU",
        city="Budapest",
        ip_address="10.10.10.10",
        is_active=True,
    )
    db_session.add(server)
    db_session.flush()

    device = Device(
        user_id=admin_user.id,
        device_id="device-obs-1",
        platform="android",
        app_version="1.2.3",
        is_active=True,
    )
    db_session.add(device)
    db_session.flush()

    base = datetime.utcnow().replace(microsecond=0)
    e1 = ObservabilityEvent(
        event_time=base - timedelta(minutes=3),
        event_name="VPN_CONNECT_PREPARE_STARTED",
        severity="info",
        source="backend",
        user_id=admin_user.id,
        device_id=device.id,
        server_id=server.id,
        vpn_session_id="sess-A",
        message="prepare start",
        attrs_json={},
        schema_version=1,
    )
    e2 = ObservabilityEvent(
        event_time=base - timedelta(minutes=2),
        event_name="VPN_CONNECT_PREPARE_FINISHED",
        severity="info",
        source="backend",
        user_id=admin_user.id,
        device_id=device.id,
        server_id=server.id,
        vpn_session_id="sess-A",
        message="prepare finish",
        attrs_json={},
        schema_version=1,
    )
    e3 = ObservabilityEvent(
        event_time=base - timedelta(minutes=1),
        event_name="VPN_TUNNEL_ESTABLISHED",
        severity="info",
        source="backend",
        user_id=admin_user.id,
        device_id=device.id,
        server_id=server.id,
        vpn_session_id="sess-A",
        message="tunnel up",
        attrs_json={},
        schema_version=1,
    )
    db_session.add_all([e1, e2, e3])
    db_session.flush()

    # Два client_log в одной сессии: ближний и дальний.
    near_dt = e3.event_time + timedelta(seconds=20)
    far_dt = e3.event_time + timedelta(minutes=5)
    db_session.add_all(
        [
            ClientLog(
                user_id=admin_user.id,
                device_id=device.id,
                server_id=server.id,
                event_type="connection_error",
                protocol="xray_vless",
                error_code="NEAR_ERR",
                message="near log",
                app_version="1.2.3",
                platform="android",
                vpn_session_id="sess-A",
                created_at=near_dt,
            ),
            ClientLog(
                user_id=admin_user.id,
                device_id=device.id,
                server_id=server.id,
                event_type="connection_error",
                protocol="xray_vless",
                error_code="FAR_ERR",
                message="far log",
                app_version="1.2.3",
                platform="android",
                vpn_session_id="sess-A",
                created_at=far_dt,
            ),
            ConnectionLog(
                user_id=admin_user.id,
                device_id=device.id,
                server_id=server.id,
                connection_type="connect",
                connected_at=e3.event_time + timedelta(seconds=15),
                vpn_session_id="sess-A",
            ),
            TelemetryEvent(
                user_id=admin_user.id,
                device_id=device.id,
                server_id=server.id,
                protocol_code="xray_vless",
                event_type="connect_success",
                timestamp=e3.event_time + timedelta(seconds=10),
                vpn_session_id="sess-A",
                app_version="1.2.3",
                platform="android",
            ),
        ]
    )
    db_session.commit()
    return {"server": server, "device": device, "events": [e1, e2, e3]}


def test_events_basic_contract_backwards_compatible(client, admin_token, seed_obs_data):
    r = client.get(
        "/api/admin/observability/events",
        headers={"Authorization": f"Bearer {admin_token}"},
        params={"limit": 2},
    )
    assert r.status_code == 200
    data = r.json()
    assert "items" in data
    assert "next_cursor" in data
    assert "prev_cursor" in data
    assert data.get("detail_level") == "basic"
    assert len(data["items"]) == 2
    first = data["items"][0]
    # Базовый контракт полей (backward compatibility).
    assert "event_name" in first
    assert "severity" in first
    assert "vpn_session_id" in first
    assert "attrs" in first


def test_events_cursor_and_filters(client, admin_token, seed_obs_data):
    first_page = client.get(
        "/api/admin/observability/events",
        headers={"Authorization": f"Bearer {admin_token}"},
        params={"limit": 2, "user_id": seed_obs_data["events"][0].user_id},
    )
    assert first_page.status_code == 200
    d1 = first_page.json()
    assert len(d1["items"]) == 2
    assert d1["next_cursor"]

    second_page = client.get(
        "/api/admin/observability/events",
        headers={"Authorization": f"Bearer {admin_token}"},
        params={
            "limit": 2,
            "user_id": seed_obs_data["events"][0].user_id,
            "cursor": d1["next_cursor"],
            "cursor_direction": "next",
        },
    )
    assert second_page.status_code == 200
    d2 = second_page.json()
    assert len(d2["items"]) >= 1


def test_events_enriched_contains_context_and_near_event_logs(client, admin_token, seed_obs_data):
    r = client.get(
        "/api/admin/observability/events",
        headers={"Authorization": f"Bearer {admin_token}"},
        params={
            "detail_level": "enriched",
            "correlation_window_seconds": 180,
            "event_name": "VPN_TUNNEL_ESTABLISHED",
            "limit": 5,
        },
    )
    assert r.status_code == 200
    data = r.json()
    assert data.get("detail_level") == "enriched"
    assert data.get("analytics_backend") in ("postgres", "clickhouse", "loki")
    assert len(data["items"]) == 1
    item = data["items"][0]
    assert item["user_context"] is not None
    assert item["device_context"] is not None
    assert item["server_context"] is not None
    assert item["related_logs"]["client_log"] is not None
    # Проверяем near-event корреляцию: выбран ближний лог, а не дальний.
    assert item["related_logs"]["client_log"]["error_code"] == "NEAR_ERR"


def test_config_trace_returns_match_mismatch_by_request_id(client, admin_token, seed_obs_data, db_session):
    base = datetime.utcnow().replace(microsecond=0)
    db_session.add_all(
        [
            ObservabilityEvent(
                event_time=base,
                event_name="VPN_CONNECT_PREPARE_FINISHED",
                severity="info",
                source="backend",
                request_id="req-trace-1",
                protocol="xray_vless",
                stage="prepare",
                outcome="success",
                config_revision="sha256:aaa",
                config_hash_expected="sha256:aaa",
                config_hash_actual="sha256:aaa",
                attrs_json={"payload_fingerprint": "sha256:aaa", "active_config_hash": "sha256:aaa"},
                schema_version=1,
            ),
            ObservabilityEvent(
                event_time=base + timedelta(seconds=1),
                event_name="VPN_CONNECT_PREPARE_FINISHED",
                severity="warn",
                source="backend",
                request_id="req-trace-1",
                protocol="xray_vless",
                stage="prepare",
                outcome="failure",
                config_revision="sha256:bbb",
                config_hash_expected="sha256:bbb",
                config_hash_actual="sha256:ccc",
                attrs_json={"payload_fingerprint": "sha256:bbb", "active_config_hash": "sha256:ccc"},
                schema_version=1,
            ),
        ]
    )
    db_session.commit()

    r = client.get(
        "/api/admin/observability/config-trace",
        headers={"Authorization": f"Bearer {admin_token}"},
        params={"request_id": "req-trace-1"},
    )
    assert r.status_code == 200
    data = r.json()
    assert data["summary"]["request_id"] == "req-trace-1"
    assert data["summary"]["event_count"] == 2
    assert data["summary"]["matches"] == 1
    assert data["summary"]["mismatches"] == 1
    assert len(data["items"]) == 2
    statuses = {item["comparison_status"] for item in data["items"]}
    assert "match" in statuses
    assert "mismatch" in statuses


def test_session_diagnostics_classifies_public_timeout_path(client, admin_token, seed_obs_data, db_session):
    base = datetime.utcnow().replace(microsecond=0)
    server = seed_obs_data["server"]
    device = seed_obs_data["device"]
    user_id = seed_obs_data["events"][0].user_id
    db_session.add(
        ObservabilityEvent(
            event_time=base,
            event_name="VPN_CONNECT_APPLY_CONFIRMED",
            severity="info",
            source="backend",
            vpn_session_id="sess-diag-1",
            user_id=user_id,
            device_id=device.id,
            server_id=server.id,
            stage="apply",
            outcome="success",
            schema_version=1,
            attrs_json={},
        )
    )
    db_session.add_all(
        [
            ClientLog(
                user_id=user_id,
                device_id=device.id,
                server_id=server.id,
                event_type="connectivity_probe",
                protocol="xray_vless",
                message="connectivity_probe",
                vpn_session_id="sess-diag-1",
                error_details={
                    "public_ok": False,
                    "api_ok": True,
                    "public_failure_class": "timeout",
                    "api_failure_class": "none",
                },
                created_at=base + timedelta(seconds=5),
            ),
            ClientLog(
                user_id=user_id,
                device_id=device.id,
                server_id=server.id,
                event_type="connection_error",
                protocol="xray_vless",
                message="connectivity_commit_failed",
                error_code="degraded_connectivity",
                vpn_session_id="sess-diag-1",
                created_at=base + timedelta(seconds=6),
            ),
        ]
    )
    db_session.commit()

    r = client.get(
        "/api/admin/observability/session-diagnostics",
        headers={"Authorization": f"Bearer {admin_token}"},
        params={"vpn_session_id": "sess-diag-1"},
    )
    assert r.status_code == 200
    data = r.json()
    assert data["vpn_session_id"] == "sess-diag-1"
    assert data["diagnostic"]["root_cause"] == "data_plane_egress_timeout_public_only"
    assert data["diagnostic"]["confidence"] == "high"
    assert data["counters"]["client_logs"] >= 2


def test_session_diagnostics_can_create_and_dedup_incident(client, admin_token, seed_obs_data, db_session):
    base = datetime.utcnow().replace(microsecond=0)
    server = seed_obs_data["server"]
    device = seed_obs_data["device"]
    user_id = seed_obs_data["events"][0].user_id
    db_session.add(
        ObservabilityEvent(
            event_time=base,
            event_name="VPN_CONNECT_APPLY_FAILED",
            severity="error",
            source="backend",
            vpn_session_id="sess-diag-incident-1",
            user_id=user_id,
            device_id=device.id,
            server_id=server.id,
            stage="apply",
            outcome="failure",
            reason_code="apply_not_confirmed",
            message="Apply timeout",
            schema_version=1,
            attrs_json={},
        )
    )
    db_session.commit()

    r1 = client.get(
        "/api/admin/observability/session-diagnostics",
        headers={"Authorization": f"Bearer {admin_token}"},
        params={"vpn_session_id": "sess-diag-incident-1", "create_incident": "true"},
    )
    assert r1.status_code == 200
    d1 = r1.json()
    assert d1["diagnostic"]["root_cause"] == "control_plane_apply_not_confirmed"
    assert d1["incident"] is not None
    inc_id = d1["incident"]["id"]

    r2 = client.get(
        "/api/admin/observability/session-diagnostics",
        headers={"Authorization": f"Bearer {admin_token}"},
        params={"vpn_session_id": "sess-diag-incident-1", "create_incident": "true"},
    )
    assert r2.status_code == 200
    d2 = r2.json()
    assert d2["incident"] is not None
    assert d2["incident"]["id"] == inc_id

    count = (
        db_session.query(ObservabilityIncident)
        .filter(ObservabilityIncident.incident_key.like("session_diag:sess-diag-incident-1:%"))
        .count()
    )
    assert count == 1

"""Тесты edge-агента: poll assignment и result (фаза 2)."""
import base64
import json

import pytest
from fastapi.testclient import TestClient

from main import app
from core.database import get_db
from api.internal_node import hash_node_token
from datetime import datetime

from domain.models.server import ConnectionLog, Server
from domain.models.edge_node_assignment import EdgeNodeAssignment
from domain.models.user import Device, User


@pytest.fixture
def edge_server(db_session):
    token = "assignment-test-token"
    server = Server(
        name="Edge assignment node",
        ip_address="10.0.0.88",
        country="RU",
        is_active=True,
        wireguard_port=51820,
        edge_agent_token_hash=hash_node_token(token),
    )
    db_session.add(server)
    db_session.commit()
    db_session.refresh(server)
    return server, token


@pytest.fixture
def assignment_client(db_session, edge_server):
    def override_get_db():
        yield db_session

    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as client:
        yield client
    app.dependency_overrides.pop(get_db, None)


def test_poll_defer_apply_xray_when_active_sessions(assignment_client, edge_server, db_session):
    server, token = edge_server
    user = User(
        email="edge-defer@example.com",
        password_hash="x",
        is_active=True,
    )
    db_session.add(user)
    db_session.commit()
    db_session.refresh(user)
    dev = Device(
        user_id=user.id,
        device_id="edge-defer-dev",
        is_active=True,
    )
    db_session.add(dev)
    db_session.commit()
    db_session.refresh(dev)
    log = ConnectionLog(
        user_id=user.id,
        device_id=dev.id,
        server_id=server.id,
        connection_type="connect",
        connected_at=datetime.utcnow(),
        disconnected_at=None,
    )
    db_session.add(log)
    cfg = b'{"log":{}}'
    b64 = base64.standard_b64encode(cfg).decode("ascii")
    row = EdgeNodeAssignment(
        id="test-asg-defer",
        server_id=server.id,
        assignment_type="apply_xray_config",
        payload_json=json.dumps(
            {
                "config_b64": b64,
                "expected_hash": "sha256:any",
                "deadline_at": None,
            }
        ),
        status="pending",
    )
    db_session.add(row)
    db_session.commit()

    r = assignment_client.get(
        "/api/internal/node/v1/assignment",
        params={"node_id": server.id},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 200
    assert r.json().get("assignment") is None
    db_session.refresh(row)
    assert row.status == "pending"


def test_poll_empty(assignment_client, edge_server):
    server, token = edge_server
    r = assignment_client.get(
        "/api/internal/node/v1/assignment",
        params={"node_id": server.id},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 200
    assert r.json().get("assignment") is None


def test_poll_and_result_flow(assignment_client, edge_server, db_session):
    server, token = edge_server
    cfg = b'{"log":{}}'
    b64 = base64.standard_b64encode(cfg).decode("ascii")
    row = EdgeNodeAssignment(
        id="test-asg-001",
        server_id=server.id,
        assignment_type="apply_xray_config",
        payload_json=json.dumps(
            {
                "config_b64": b64,
                "expected_hash": "sha256:any",
                "deadline_at": None,
            }
        ),
        status="pending",
    )
    db_session.add(row)
    db_session.commit()

    r = assignment_client.get(
        "/api/internal/node/v1/assignment",
        params={"node_id": server.id},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 200
    data = r.json()["assignment"]
    assert data is not None
    assert data["id"] == "test-asg-001"
    assert data["type"] == "apply_xray_config"
    assert data["config_b64"] == b64

    db_session.refresh(row)
    assert row.status == "dispatched"

    r2 = assignment_client.post(
        f"/api/internal/node/v1/assignment/{row.id}/result",
        params={"node_id": server.id},
        headers={"Authorization": f"Bearer {token}"},
        json={
            "status": "ok",
            "message": "applied",
            "applied_config_hash": "sha256:deadbeef",
            "xray_reloaded_at": "2026-01-01T12:00:00Z",
        },
    )
    assert r2.status_code == 200
    db_session.refresh(row)
    assert row.status == "completed"
    assert row.result_status == "ok"
    assert row.applied_config_hash == "sha256:deadbeef"


def test_result_without_poll_conflict(assignment_client, edge_server, db_session):
    server, token = edge_server
    row = EdgeNodeAssignment(
        id="test-asg-002",
        server_id=server.id,
        assignment_type="apply_xray_config",
        payload_json=json.dumps({"config_b64": "e30=", "expected_hash": "sha256:x"}),
        status="pending",
    )
    db_session.add(row)
    db_session.commit()

    r = assignment_client.post(
        f"/api/internal/node/v1/assignment/{row.id}/result",
        params={"node_id": server.id},
        headers={"Authorization": f"Bearer {token}"},
        json={"status": "ok"},
    )
    assert r.status_code == 409

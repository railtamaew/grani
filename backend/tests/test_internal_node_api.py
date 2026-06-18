"""Тесты POST /api/internal/node/v1/heartbeat (edge-агент фаза 1)."""
import pytest
from fastapi.testclient import TestClient

from main import app
from core.database import get_db
from api.internal_node import hash_node_token
from domain.models.server import Server


@pytest.fixture
def edge_server(db_session):
    token = "test-node-token-secret"
    server = Server(
        name="Edge test node",
        ip_address="10.0.0.99",
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
def internal_node_client(db_session, edge_server):
    def override_get_db():
        yield db_session

    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as client:
        yield client
    app.dependency_overrides.pop(get_db, None)


def test_heartbeat_missing_auth(internal_node_client, edge_server):
    server, _ = edge_server
    r = internal_node_client.post(
        "/api/internal/node/v1/heartbeat",
        json={
            "node_id": server.id,
            "config_hash": "sha256:abc",
            "xray_running": True,
            "agent_version": "0.1.0",
        },
    )
    assert r.status_code == 401


def test_heartbeat_invalid_token(internal_node_client, edge_server):
    server, _ = edge_server
    r = internal_node_client.post(
        "/api/internal/node/v1/heartbeat",
        headers={"Authorization": "Bearer wrong-token"},
        json={
            "node_id": server.id,
            "config_hash": "sha256:abc",
            "xray_running": False,
            "agent_version": "0.1.0",
        },
    )
    assert r.status_code == 401


def test_heartbeat_wrong_node_id(internal_node_client, edge_server):
    server, token = edge_server
    r = internal_node_client.post(
        "/api/internal/node/v1/heartbeat",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "node_id": server.id + 999,
            "config_hash": "sha256:abc",
            "xray_running": False,
            "agent_version": "0.1.0",
        },
    )
    assert r.status_code == 403


def test_heartbeat_ok(internal_node_client, edge_server, db_session):
    server, token = edge_server
    r = internal_node_client.post(
        "/api/internal/node/v1/heartbeat",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "node_id": server.id,
            "config_hash": "sha256:deadbeef",
            "xray_running": True,
            "agent_version": "0.1.0",
        },
    )
    assert r.status_code == 200
    data = r.json()
    assert data.get("next_poll_sec") == 30

    db_session.refresh(server)
    assert server.edge_reported_config_hash == "sha256:deadbeef"
    assert server.edge_agent_version == "0.1.0"
    assert server.edge_last_heartbeat_at is not None

"""Тесты Celery-задачи apply_xray_config_to_vpn (edge vs SSH)."""
import json
from datetime import datetime
from unittest.mock import patch

import pytest

from api.internal_node import hash_node_token
from domain.models.edge_node_assignment import EdgeNodeAssignment
from domain.models.server import ConnectionLog
from domain.models.user import User, Device
from models.server import Server
from services.tasks.vpn_tasks import apply_xray_config_to_vpn


class _SessionNoClose:
    """Обёртка: задача вызывает session.close() — не закрываем тестовую сессию."""

    def __init__(self, inner):
        self._s = inner

    def query(self, *a, **kw):
        return self._s.query(*a, **kw)

    def commit(self):
        return self._s.commit()

    def rollback(self):
        return self._s.rollback()

    def add(self, obj):
        return self._s.add(obj)

    def refresh(self, obj):
        return self._s.refresh(obj)

    def close(self):
        pass


@pytest.fixture
def server_no_edge(db_session):
    s = Server(
        name="ssh-only",
        ip_address="10.2.2.1",
        country="RU",
        is_active=True,
        wireguard_port=51820,
    )
    db_session.add(s)
    db_session.commit()
    db_session.refresh(s)
    return s


@pytest.fixture
def server_with_edge(db_session):
    s = Server(
        name="edge-node",
        ip_address="10.2.2.2",
        country="RU",
        is_active=True,
        wireguard_port=51820,
        edge_agent_token_hash=hash_node_token("edge-secret"),
    )
    db_session.add(s)
    db_session.commit()
    db_session.refresh(s)
    return s


def test_apply_xray_via_edge_queues_assignment(db_session, server_with_edge):
    cfg = {"log": {"loglevel": "warning"}}
    with patch(
        "services.tasks.vpn_tasks.SessionLocal",
        return_value=_SessionNoClose(db_session),
    ):
        with patch("services.tasks.vpn_tasks.XrayManager") as mock_xm:
            result = apply_xray_config_to_vpn.run(server_with_edge.id, json.dumps(cfg))
    assert result["status"] == "success"
    assert result.get("via") == "edge"
    assert "edge_assignment_id" in result
    row = (
        db_session.query(EdgeNodeAssignment)
        .filter(EdgeNodeAssignment.id == result["edge_assignment_id"])
        .first()
    )
    assert row is not None
    assert row.status == "pending"
    inst = mock_xm.return_value
    inst.apply_config_to_server.assert_not_called()
    inst.set_last_apply_state.assert_called_once()


def test_apply_xray_ssh_deferred_when_active_session(db_session, server_no_edge):
    cfg = {"log": {"loglevel": "debug"}}
    user = User(
        email="defer-ssh@example.com",
        password_hash="x",
        is_active=True,
    )
    db_session.add(user)
    db_session.commit()
    db_session.refresh(user)
    dev = Device(
        user_id=user.id,
        device_id="defer-dev-1",
        current_server_id=server_no_edge.id,
        is_active=True,
        is_vpn_enabled=True,
        vpn_protocol="vless",
        vpn_client_id="22222222-2222-2222-2222-222222222222",
    )
    db_session.add(dev)
    db_session.commit()
    log = ConnectionLog(
        user_id=user.id,
        device_id=dev.id,
        server_id=server_no_edge.id,
        connection_type="connect",
        connected_at=datetime.utcnow(),
        disconnected_at=None,
    )
    db_session.add(log)
    db_session.commit()
    with patch(
        "services.tasks.vpn_tasks.SessionLocal",
        return_value=_SessionNoClose(db_session),
    ):
        with patch("services.tasks.vpn_tasks.XrayManager") as mock_xm:
            inst = mock_xm.return_value
            with patch.object(apply_xray_config_to_vpn, "apply_async") as mock_async:
                result = apply_xray_config_to_vpn.run(server_no_edge.id, json.dumps(cfg))
    assert result["status"] == "deferred"
    assert result.get("reason") == "active_xray_sessions"
    mock_async.assert_called_once()
    inst.apply_config_to_server.assert_not_called()


def test_apply_xray_without_edge_calls_ssh_path(db_session, server_no_edge):
    cfg = {"log": {"loglevel": "debug"}}
    with patch(
        "services.tasks.vpn_tasks.SessionLocal",
        return_value=_SessionNoClose(db_session),
    ):
        with patch("services.tasks.vpn_tasks.XrayManager") as mock_xm:
            inst = mock_xm.return_value
            inst.apply_config_to_server.return_value = True
            result = apply_xray_config_to_vpn.run(server_no_edge.id, json.dumps(cfg))
    assert result["status"] == "success"
    assert result.get("via") is None
    inst.apply_config_to_server.assert_called_once()
    args, _ = inst.apply_config_to_server.call_args
    assert args[0].id == server_no_edge.id
    assert args[1] == cfg


def test_apply_xray_ssh_skips_when_sha_already_applied(db_session, server_no_edge):
    cfg = {"log": {"loglevel": "debug"}}
    with patch(
        "services.tasks.vpn_tasks.SessionLocal",
        return_value=_SessionNoClose(db_session),
    ):
        with patch("services.tasks.vpn_tasks.XrayManager") as mock_xm:
            inst = mock_xm.return_value
            inst._calc_config_sha256.return_value = "samehash"
            inst.get_last_apply_state.return_value = {
                "config_sha256": "samehash",
                "status": "applied",
            }
            result = apply_xray_config_to_vpn.run(server_no_edge.id, json.dumps(cfg))
    assert result["status"] == "success"
    assert result.get("skipped") == "duplicate_sha256"
    inst.apply_config_to_server.assert_not_called()

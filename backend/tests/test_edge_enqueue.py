"""Юнит-тесты постановки заданий edge при обновлении Xray."""
import json
from unittest.mock import patch

from api.internal_node import hash_node_token
from domain.models.server import Server
from domain.models.edge_node_assignment import EdgeNodeAssignment
from services.edge_enqueue import (
    enqueue_apply_xray_config,
    try_commit_apply_xray_config_edge,
    try_commit_apply_xray_config_edge_with_id,
)


def test_enqueue_skips_without_token(db_session):
    s = Server(
        name="No edge",
        ip_address="10.1.1.1",
        country="RU",
        is_active=True,
        wireguard_port=51820,
    )
    db_session.add(s)
    db_session.commit()
    db_session.refresh(s)
    cfg = {"log": {"loglevel": "warning"}}
    assert enqueue_apply_xray_config(db_session, s, cfg) is None


def test_enqueue_creates_assignment(db_session):
    s = Server(
        name="With edge",
        ip_address="10.1.1.2",
        country="RU",
        is_active=True,
        wireguard_port=51820,
        edge_agent_token_hash=hash_node_token("secret"),
    )
    db_session.add(s)
    db_session.commit()
    db_session.refresh(s)
    cfg = {"log": {"loglevel": "debug"}}
    aid = enqueue_apply_xray_config(db_session, s, cfg)
    assert aid is not None
    db_session.commit()
    row = db_session.query(EdgeNodeAssignment).filter(EdgeNodeAssignment.id == aid).first()
    assert row is not None
    assert row.status == "pending"
    assert row.assignment_type == "apply_xray_config"
    payload = json.loads(row.payload_json)
    assert "config_b64" in payload
    assert payload["expected_hash"].startswith("sha256:")


def test_try_commit_uses_test_db(db_session):
    s = Server(
        name="try-commit",
        ip_address="10.1.1.3",
        country="RU",
        is_active=True,
        wireguard_port=51820,
        edge_agent_token_hash=hash_node_token("x"),
    )
    db_session.add(s)
    db_session.commit()
    db_session.refresh(s)
    cfg = {"a": 1}
    class _S:
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

        def close(self):
            pass

    with patch("core.database.SessionLocal", return_value=_S(db_session)):
        assert try_commit_apply_xray_config_edge(s, cfg) is True
    row = (
        db_session.query(EdgeNodeAssignment)
        .filter(EdgeNodeAssignment.server_id == s.id)
        .first()
    )
    assert row is not None


def test_try_commit_with_id_returns_assignment_id(db_session):
    s = Server(
        name="try-commit-with-id",
        ip_address="10.1.1.4",
        country="RU",
        is_active=True,
        wireguard_port=51820,
        edge_agent_token_hash=hash_node_token("id"),
    )
    db_session.add(s)
    db_session.commit()
    db_session.refresh(s)

    cfg = {"x": 1}

    class _S:
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

        def close(self):
            pass

    with patch("core.database.SessionLocal", return_value=_S(db_session)):
        aid = try_commit_apply_xray_config_edge_with_id(s, cfg)

    assert isinstance(aid, str) and len(aid) > 10
    row = db_session.query(EdgeNodeAssignment).filter(EdgeNodeAssignment.id == aid).first()
    assert row is not None
    assert row.server_id == s.id


def test_enqueue_reuses_pending_assignment_with_same_hash(db_session):
    s = Server(
        name="reuse-same-hash",
        ip_address="10.1.1.5",
        country="RU",
        is_active=True,
        wireguard_port=51820,
        edge_agent_token_hash=hash_node_token("reuse"),
    )
    db_session.add(s)
    db_session.commit()
    db_session.refresh(s)

    cfg = {"log": {"loglevel": "warning"}, "inbounds": []}
    aid1 = enqueue_apply_xray_config(db_session, s, cfg)
    db_session.commit()
    aid2 = enqueue_apply_xray_config(db_session, s, cfg)
    db_session.commit()

    assert aid1 == aid2
    rows = (
        db_session.query(EdgeNodeAssignment)
        .filter(EdgeNodeAssignment.server_id == s.id)
        .all()
    )
    assert len(rows) == 1


def test_enqueue_reuses_assignment_for_same_semantic_config_different_key_order(db_session):
    s = Server(
        name="reuse-semantic-same-config",
        ip_address="10.1.1.6",
        country="RU",
        is_active=True,
        wireguard_port=51820,
        edge_agent_token_hash=hash_node_token("reuse-semantic"),
    )
    db_session.add(s)
    db_session.commit()
    db_session.refresh(s)

    cfg_a = {
        "log": {"loglevel": "warning"},
        "dns": {"servers": ["1.1.1.1", "9.9.9.9"]},
        "routing": {"rules": [{"type": "field", "outboundTag": "proxy"}]},
    }
    cfg_b = {
        "routing": {"rules": [{"type": "field", "outboundTag": "proxy"}]},
        "dns": {"servers": ["1.1.1.1", "9.9.9.9"]},
        "log": {"loglevel": "warning"},
    }

    aid1 = enqueue_apply_xray_config(db_session, s, cfg_a)
    db_session.commit()
    aid2 = enqueue_apply_xray_config(db_session, s, cfg_b)
    db_session.commit()

    assert aid1 == aid2
    rows = (
        db_session.query(EdgeNodeAssignment)
        .filter(EdgeNodeAssignment.server_id == s.id)
        .all()
    )
    assert len(rows) == 1

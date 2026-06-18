"""
Постановка заданий edge-агента из фона (после create-client / обновления Xray на ноде).
Если у сервера задан edge_agent_token_hash, конфиг уходит в очередь вместо немедленного SSH.
"""
from __future__ import annotations

import base64
import hashlib
import json
import logging
import uuid
from typing import Any, Dict, Optional

from datetime import datetime, timedelta

from sqlalchemy import func
from sqlalchemy.orm import Session

from core.config import settings
from domain.models.edge_node_assignment import EdgeNodeAssignment
from domain.models.server import ConnectionLog
from domain.models.server import Server

logger = logging.getLogger(__name__)


def count_active_xray_sessions_for_server(db: Session, server_id: int) -> int:
    """
    Активные VPN-сессии на сервере по факту connection_logs.
    Считаем активными connect-сессии без disconnected_at за lookback-окно.
    """
    if server_id <= 0:
        return 0
    lookback_sec = max(30, int(getattr(settings, "xray_active_session_lookback_sec", 900) or 900))
    threshold = datetime.utcnow() - timedelta(seconds=lookback_sec)
    q = (
        db.query(func.count(ConnectionLog.id))
        .filter(
            ConnectionLog.server_id == server_id,
            ConnectionLog.connection_type == "connect",
            ConnectionLog.disconnected_at.is_(None),
            ConnectionLog.connected_at >= threshold,
        )
    )
    return int(q.scalar() or 0)


def _config_json_bytes(config: Dict[str, Any]) -> bytes:
    # Детерминированная сериализация:
    # - sort_keys=True убирает флапы из-за разного порядка ключей
    # - тем же байтовым представлением считаем hash и отправляем агенту
    #   (чтобы одинаковая по смыслу конфигурация не вызывала лишний reload/restart Xray).
    return json.dumps(config, indent=2, sort_keys=True).encode("utf-8")


def enqueue_apply_xray_config(db: Session, server: Server, config: Dict[str, Any]) -> Optional[str]:
    """
    Создаёт pending assignment apply_xray_config, если у сервера настроен edge-агент.
    Возвращает id задания или None (нужен классический SSH).
    Вызывающий должен сделать db.commit().
    """
    if not getattr(server, "edge_agent_token_hash", None):
        return None
    raw = _config_json_bytes(config)
    digest = hashlib.sha256(raw).hexdigest()
    expected_hash = f"sha256:{digest}"
    now = datetime.utcnow()
    debounce_sec = max(0, int(getattr(settings, "xray_edge_enqueue_debounce_sec", 45) or 45))
    # Идемпотентность: не плодим повторные apply одного и того же конфига.
    # Это убирает лишние reload/restart на ноде и флапы data-plane.
    recent = (
        db.query(EdgeNodeAssignment)
        .filter(
            EdgeNodeAssignment.server_id == server.id,
            EdgeNodeAssignment.assignment_type == "apply_xray_config",
            EdgeNodeAssignment.status.in_(("pending", "dispatched")),
        )
        .order_by(EdgeNodeAssignment.created_at.desc())
        .limit(20)
        .all()
    )
    for row in recent:
        try:
            payload = json.loads(row.payload_json or "{}")
        except Exception:
            payload = {}
        if payload.get("expected_hash") == expected_hash:
            logger.info(
                "[edge_enqueue] reuse existing assignment server_id=%s assignment_id=%s hash_prefix=%s",
                server.id,
                row.id,
                expected_hash[:32],
            )
            return row.id
        # Coalescing: если уже есть свежий pending assignment, обновляем его payload
        # вместо создания новой записи. Это убирает рост pending_state и лишние apply-циклы.
        created_at = row.created_at or now
        age_sec = max(0.0, (now - created_at).total_seconds())
        if row.status == "pending" and age_sec <= float(debounce_sec):
            payload["config_b64"] = base64.standard_b64encode(raw).decode("ascii")
            payload["expected_hash"] = expected_hash
            payload.setdefault("deadline_at", None)
            row.payload_json = json.dumps(payload)
            db.add(row)
            logger.info(
                "[edge_enqueue] coalesced pending assignment server_id=%s assignment_id=%s age_sec=%.1f hash_prefix=%s",
                server.id,
                row.id,
                age_sec,
                expected_hash[:32],
            )
            return row.id

    b64 = base64.standard_b64encode(raw).decode("ascii")
    aid = str(uuid.uuid4())
    row = EdgeNodeAssignment(
        id=aid,
        server_id=server.id,
        assignment_type="apply_xray_config",
        payload_json=json.dumps(
            {
                "config_b64": b64,
                "expected_hash": expected_hash,
                "deadline_at": None,
            }
        ),
        status="pending",
    )
    db.add(row)
    logger.info(
        "[edge_enqueue] server_id=%s assignment_id=%s expected_hash_prefix=%s",
        server.id,
        aid,
        expected_hash[:32],
    )
    return aid


def try_commit_apply_xray_config_edge_with_id(server: Server, config: Dict[str, Any]) -> Optional[str]:
    """
    Если у сервера есть edge-токен: перечитывает сервер из БД, ставит задание, commit.
    Возвращает assignment_id, если очередь edge использована (SSH для записи конфига не нужен).
    """
    if not getattr(server, "edge_agent_token_hash", None):
        return None
    from core.database import SessionLocal

    db = SessionLocal()
    try:
        s = db.query(Server).filter(Server.id == server.id).first()
        if not s or not getattr(s, "edge_agent_token_hash", None):
            return None
        aid = enqueue_apply_xray_config(db, s, config)
        if not aid:
            return None
        db.commit()
        logger.info("[edge_enqueue] inline server_id=%s assignment_id=%s", s.id, aid)
        return aid
    except Exception:
        logger.exception(
            "[edge_enqueue] inline failed server_id=%s",
            getattr(server, "id", None),
        )
        try:
            db.rollback()
        except Exception:
            pass
        return None
    finally:
        db.close()


def try_commit_apply_xray_config_edge(server: Server, config: Dict[str, Any]) -> bool:
    """
    Backward-compatible API.
    True, если постановка в edge-очередь успешна.
    """
    return bool(try_commit_apply_xray_config_edge_with_id(server, config))

"""
Внутренний API для edge-агента на VPN-нодах.
Фаза 1: heartbeat. Фаза 2: poll assignment + result.
Аутентификация: Authorization: Bearer <node_token>; в БД хранится SHA-256 hex токена.
"""
from __future__ import annotations

import hashlib
import json
import logging
import time
from datetime import datetime, timedelta
from typing import Any, Dict, Literal, Optional

from fastapi import APIRouter, Depends, Header, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import and_, or_
from sqlalchemy.orm import Session

from core.config import settings
from core.database import get_db
from domain.models.edge_node_assignment import EdgeNodeAssignment
from domain.models.server import Server
from services.edge_enqueue import count_active_xray_sessions_for_server

logger = logging.getLogger(__name__)

router = APIRouter()

# Повторная выдача задания в статусе dispatched, если не пришёл result дольше этого времени
DISPATCH_LEASE = timedelta(minutes=10)


def hash_node_token(raw: str) -> str:
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


class HeartbeatRequest(BaseModel):
    node_id: int = Field(..., description="ID сервера в таблице servers (должен совпадать с токеном)")
    config_hash: str = Field(..., min_length=1, max_length=256)
    xray_running: bool = False
    agent_version: str = Field("", max_length=64)


class HeartbeatResponse(BaseModel):
    next_poll_sec: int = 30


class AssignmentDto(BaseModel):
    id: str
    type: str
    config_b64: str = ""
    expected_hash: str = ""
    deadline_at: Optional[str] = None


class AssignmentPollResponse(BaseModel):
    assignment: Optional[AssignmentDto] = None


class AssignmentResultRequest(BaseModel):
    status: Literal["ok", "failed"]
    message: Optional[str] = Field(None, max_length=4000)
    applied_config_hash: Optional[str] = Field(None, max_length=256)
    xray_reloaded_at: Optional[str] = None  # ISO8601


class AssignmentResultResponse(BaseModel):
    ok: bool = True


def get_server_for_node_token(
    authorization: Optional[str] = Header(None),
    db: Session = Depends(get_db),
) -> Server:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing or invalid Authorization header",
        )
    token = authorization[7:].strip()
    if not token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Empty bearer token",
        )
    token_hash = hash_node_token(token)
    server = (
        db.query(Server)
        .filter(Server.edge_agent_token_hash == token_hash)
        .first()
    )
    if server is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid node token",
        )
    return server


def _verify_node_id(server: Server, node_id: int, t0: float) -> None:
    if node_id != server.id:
        elapsed_ms = int((time.perf_counter() - t0) * 1000)
        logger.info(
            "[edge_agent_heartbeat] server_id=%s status=%s elapsed_ms=%s",
            server.id,
            status.HTTP_403_FORBIDDEN,
            elapsed_ms,
        )
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="node_id does not match token",
        )


@router.post("/heartbeat", response_model=HeartbeatResponse)
def edge_heartbeat(
    body: HeartbeatRequest,
    db: Session = Depends(get_db),
    server: Server = Depends(get_server_for_node_token),
):
    t0 = time.perf_counter()
    _verify_node_id(server, body.node_id, t0)

    try:
        server.edge_last_heartbeat_at = datetime.utcnow()
        server.edge_reported_config_hash = body.config_hash[:256]
        server.edge_agent_version = (body.agent_version or "")[:64] or None
        db.add(server)
        db.commit()
    except Exception:
        logger.exception("[edge_agent_heartbeat] server_id=%s db_error", server.id)
        db.rollback()
        elapsed_ms = int((time.perf_counter() - t0) * 1000)
        logger.info(
            "[edge_agent_heartbeat] server_id=%s status=%s elapsed_ms=%s xray_running=%s agent_version=%s",
            server.id,
            status.HTTP_500_INTERNAL_SERVER_ERROR,
            elapsed_ms,
            body.xray_running,
            body.agent_version or "-",
        )
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="heartbeat failed",
        )

    elapsed_ms = int((time.perf_counter() - t0) * 1000)
    logger.info(
        "[edge_agent_heartbeat] server_id=%s status=%s elapsed_ms=%s xray_running=%s agent_version=%s",
        server.id,
        status.HTTP_200_OK,
        elapsed_ms,
        body.xray_running,
        body.agent_version or "-",
    )
    return HeartbeatResponse(next_poll_sec=30)


def _payload_to_dto(a: EdgeNodeAssignment) -> AssignmentDto:
    data: Dict[str, Any] = json.loads(a.payload_json)
    return AssignmentDto(
        id=a.id,
        type=a.assignment_type,
        config_b64=data.get("config_b64") or "",
        expected_hash=data.get("expected_hash") or "",
        deadline_at=data.get("deadline_at"),
    )


@router.get("/assignment", response_model=AssignmentPollResponse)
def edge_poll_assignment(
    node_id: int,
    since: Optional[str] = None,
    db: Session = Depends(get_db),
    server: Server = Depends(get_server_for_node_token),
):
    """
    Короткий poll: одно задание в статусе pending или просроченное dispatched.
    Параметр since зарезервирован (cursor); пока не фильтрует выдачу.
    """
    t0 = time.perf_counter()
    if node_id != server.id:
        elapsed_ms = int((time.perf_counter() - t0) * 1000)
        logger.info(
            "[edge_agent_assignment] action=poll server_id=%s status=403 elapsed_ms=%s",
            server.id,
            elapsed_ms,
        )
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="node_id mismatch")

    now = datetime.utcnow()
    lease_deadline = now - DISPATCH_LEASE
    defer_max_sec = max(15, int(getattr(settings, "xray_edge_dispatch_defer_max_sec", 150) or 150))

    row = (
        db.query(EdgeNodeAssignment)
        .filter(
            EdgeNodeAssignment.server_id == server.id,
            or_(
                EdgeNodeAssignment.status == "pending",
                and_(
                    EdgeNodeAssignment.status == "dispatched",
                    EdgeNodeAssignment.dispatched_at.isnot(None),
                    EdgeNodeAssignment.dispatched_at < lease_deadline,
                ),
            ),
        )
        .order_by(EdgeNodeAssignment.created_at.asc())
        .first()
    )

    if row is None:
        elapsed_ms = int((time.perf_counter() - t0) * 1000)
        logger.info(
            "[edge_agent_assignment] action=poll server_id=%s assignment_id=- status=empty elapsed_ms=%s",
            server.id,
            elapsed_ms,
        )
        return AssignmentPollResponse(assignment=None)

    if row.assignment_type == "apply_xray_config":
        try:
            payload = json.loads(row.payload_json or "{}")
        except Exception:
            payload = {}
        expected_hash = str(payload.get("expected_hash") or "")
        reported_hash = str(getattr(server, "edge_reported_config_hash", "") or "")
        if expected_hash and reported_hash and expected_hash == reported_hash:
            row.status = "completed"
            row.result_status = "ok"
            row.result_message = "already_applied_by_hash_match"
            row.applied_config_hash = expected_hash
            row.completed_at = now
            try:
                db.add(row)
                db.commit()
            except Exception:
                db.rollback()
            elapsed_ms = int((time.perf_counter() - t0) * 1000)
            logger.info(
                "[edge_agent_assignment] action=poll_skip_applied server_id=%s assignment_id=%s "
                "hash_prefix=%s elapsed_ms=%s",
                server.id,
                row.id,
                expected_hash[:24],
                elapsed_ms,
            )
            return AssignmentPollResponse(assignment=None)
        active = count_active_xray_sessions_for_server(db, server.id)
        if active > 0:
            created = row.created_at or now
            dispatch_lag_ms = int((now - created).total_seconds() * 1000)
            dispatch_lag_sec = max(0.0, (now - created).total_seconds())
            if dispatch_lag_sec >= float(defer_max_sec):
                logger.warning(
                    "[edge_agent_assignment] action=poll_force_dispatch server_id=%s assignment_id=%s "
                    "active_sessions=%s dispatch_lag_ms=%s defer_max_sec=%s",
                    server.id,
                    row.id,
                    active,
                    dispatch_lag_ms,
                    defer_max_sec,
                )
            else:
                elapsed_ms = int((time.perf_counter() - t0) * 1000)
                logger.warning(
                    "[edge_agent_assignment] action=poll_defer server_id=%s assignment_id=%s "
                    "active_sessions=%s dispatch_lag_ms=%s elapsed_ms=%s",
                    server.id,
                    row.id,
                    active,
                    dispatch_lag_ms,
                    elapsed_ms,
                )
                return AssignmentPollResponse(assignment=None)

    row.status = "dispatched"
    row.dispatched_at = now
    try:
        db.add(row)
        db.commit()
        db.refresh(row)
    except Exception:
        logger.exception("[edge_agent_assignment] poll commit server_id=%s", server.id)
        db.rollback()
        raise HTTPException(status_code=500, detail="poll failed")

    elapsed_ms = int((time.perf_counter() - t0) * 1000)
    logger.info(
        "[edge_agent_assignment] action=poll server_id=%s assignment_id=%s type=%s status=dispatched elapsed_ms=%s",
        server.id,
        row.id,
        row.assignment_type,
        elapsed_ms,
    )
    return AssignmentPollResponse(assignment=_payload_to_dto(row))


@router.post("/assignment/{assignment_id}/result", response_model=AssignmentResultResponse)
def edge_assignment_result(
    assignment_id: str,
    body: AssignmentResultRequest,
    node_id: int,
    db: Session = Depends(get_db),
    server: Server = Depends(get_server_for_node_token),
):
    t0 = time.perf_counter()
    if node_id != server.id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="node_id mismatch")

    row = (
        db.query(EdgeNodeAssignment)
        .filter(
            EdgeNodeAssignment.id == assignment_id,
            EdgeNodeAssignment.server_id == server.id,
        )
        .first()
    )
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="assignment not found")

    if row.status in ("completed", "failed", "cancelled"):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="assignment already finalized")

    if row.status != "dispatched":
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="assignment must be claimed via GET /assignment before posting result",
        )

    now = datetime.utcnow()
    row.result_status = body.status
    row.result_message = (body.message or "")[:4000] or None
    row.applied_config_hash = (body.applied_config_hash or "")[:256] or None
    if body.xray_reloaded_at:
        try:
            raw = body.xray_reloaded_at.replace("Z", "+00:00")
            row.xray_reloaded_at = datetime.fromisoformat(raw)
            if row.xray_reloaded_at.tzinfo is not None:
                row.xray_reloaded_at = row.xray_reloaded_at.replace(tzinfo=None)
        except ValueError:
            row.xray_reloaded_at = None
    else:
        row.xray_reloaded_at = None

    row.status = "completed" if body.status == "ok" else "failed"
    row.completed_at = now

    try:
        db.add(row)
        db.commit()
    except Exception:
        logger.exception("[edge_agent_assignment] result commit server_id=%s", server.id)
        db.rollback()
        raise HTTPException(status_code=500, detail="result save failed")

    elapsed_ms = int((time.perf_counter() - t0) * 1000)
    logger.info(
        "[edge_agent_assignment] action=result server_id=%s assignment_id=%s outcome=%s elapsed_ms=%s",
        server.id,
        row.id,
        body.status,
        elapsed_ms,
    )
    return AssignmentResultResponse(ok=True)

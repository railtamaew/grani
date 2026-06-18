"""Очередь заданий для edge-агента на VPN-ноде (фаза 2)."""
from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import Column, DateTime, ForeignKey, Integer, String, Text

from core.database import Base


class EdgeNodeAssignment(Base):
    __tablename__ = "edge_node_assignments"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    server_id = Column(Integer, ForeignKey("servers.id"), nullable=False, index=True)
    assignment_type = Column(String(64), nullable=False)
    payload_json = Column(Text, nullable=False)
    status = Column(String(32), nullable=False, default="pending", index=True)
    result_status = Column(String(16), nullable=True)
    result_message = Column(Text, nullable=True)
    applied_config_hash = Column(String(256), nullable=True)
    xray_reloaded_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    dispatched_at = Column(DateTime, nullable=True)
    completed_at = Column(DateTime, nullable=True)

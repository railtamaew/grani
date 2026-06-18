from datetime import datetime

from sqlalchemy import (
    Boolean,
    Column,
    DateTime,
    ForeignKey,
    Integer,
    JSON,
    String,
    Text,
)
from sqlalchemy.orm import relationship

from core.database import Base


class ObservabilityEvent(Base):
    __tablename__ = "observability_events"

    id = Column(Integer, primary_key=True, index=True)
    event_time = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    event_name = Column(String, nullable=False, index=True)
    severity = Column(String, nullable=False, default="info", index=True)
    source = Column(String, nullable=False, default="backend", index=True)

    request_id = Column(String, nullable=True, index=True)
    trace_id = Column(String, nullable=True, index=True)
    span_id = Column(String, nullable=True, index=True)
    vpn_session_id = Column(String, nullable=True, index=True)

    user_id = Column(Integer, ForeignKey("users.id"), nullable=True, index=True)
    device_id = Column(Integer, ForeignKey("devices.id"), nullable=True, index=True)
    server_id = Column(Integer, ForeignKey("servers.id"), nullable=True, index=True)
    device_fingerprint = Column(String, nullable=True, index=True)

    protocol = Column(String, nullable=True, index=True)
    stage = Column(String, nullable=True, index=True)
    outcome = Column(String, nullable=True, index=True)
    reason_code = Column(String, nullable=True, index=True)
    message = Column(Text, nullable=True)

    config_revision = Column(String, nullable=True, index=True)
    config_hash_expected = Column(String, nullable=True)
    config_hash_actual = Column(String, nullable=True)

    attrs_json = Column(JSON, nullable=False, default=dict)
    schema_version = Column(Integer, nullable=False, default=1)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)

    user = relationship("User", foreign_keys=[user_id], lazy="select")
    device = relationship("Device", foreign_keys=[device_id], lazy="select")
    server = relationship("Server", foreign_keys=[server_id], lazy="select")


class ObservabilityIncident(Base):
    __tablename__ = "observability_incidents"

    id = Column(Integer, primary_key=True, index=True)
    incident_key = Column(String, nullable=False, index=True)
    incident_type = Column(String, nullable=False, index=True)
    severity = Column(String, nullable=False, default="P3", index=True)
    status = Column(String, nullable=False, default="open", index=True)
    title = Column(String, nullable=False)
    summary = Column(Text, nullable=True)
    evidence_json = Column(JSON, nullable=False, default=dict)

    first_seen_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    last_seen_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    assignee_user_id = Column(Integer, ForeignKey("users.id"), nullable=True, index=True)
    resolved_at = Column(DateTime, nullable=True)

    created_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    updated_at = Column(
        DateTime,
        default=datetime.utcnow,
        onupdate=datetime.utcnow,
        nullable=False,
        index=True,
    )

    assignee = relationship("User", foreign_keys=[assignee_user_id], lazy="select")
    comments = relationship(
        "ObservabilityIncidentComment",
        back_populates="incident",
        lazy="select",
    )


class ObservabilityIncidentComment(Base):
    __tablename__ = "observability_incident_comments"

    id = Column(Integer, primary_key=True, index=True)
    incident_id = Column(
        Integer,
        ForeignKey("observability_incidents.id"),
        nullable=False,
        index=True,
    )
    author_user_id = Column(Integer, ForeignKey("users.id"), nullable=True, index=True)
    comment = Column(Text, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)

    incident = relationship("ObservabilityIncident", back_populates="comments", lazy="select")
    author = relationship("User", foreign_keys=[author_user_id], lazy="select")


class EventDictionary(Base):
    __tablename__ = "event_dictionary"

    id = Column(Integer, primary_key=True, index=True)
    event_name = Column(String, nullable=False, unique=True, index=True)
    display_name_ru = Column(String, nullable=False)
    display_name_en = Column(String, nullable=False)
    default_comment_template = Column(Text, nullable=True)
    operator_hint = Column(Text, nullable=True)
    severity_default = Column(String, nullable=False, default="info")
    is_active = Column(Boolean, nullable=False, default=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    updated_at = Column(
        DateTime,
        default=datetime.utcnow,
        onupdate=datetime.utcnow,
        nullable=False,
        index=True,
    )

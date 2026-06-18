from __future__ import annotations

import logging
from typing import Any, Optional

from sqlalchemy.orm import Session

from core.request_context import get_request_id, get_vpn_session_id
from models.observability import EventDictionary, ObservabilityEvent

logger = logging.getLogger(__name__)


def emit_observability_event(
    db: Session,
    *,
    event_name: str,
    severity: str = "info",
    source: str = "backend",
    user_id: Optional[int] = None,
    device_id: Optional[int] = None,
    server_id: Optional[int] = None,
    device_fingerprint: Optional[str] = None,
    protocol: Optional[str] = None,
    stage: Optional[str] = None,
    outcome: Optional[str] = None,
    reason_code: Optional[str] = None,
    message: Optional[str] = None,
    trace_id: Optional[str] = None,
    span_id: Optional[str] = None,
    request_id: Optional[str] = None,
    vpn_session_id: Optional[str] = None,
    config_revision: Optional[str] = None,
    config_hash_expected: Optional[str] = None,
    config_hash_actual: Optional[str] = None,
    attrs: Optional[dict[str, Any]] = None,
    commit: bool = False,
) -> ObservabilityEvent:
    event = ObservabilityEvent(
        event_name=event_name,
        severity=severity,
        source=source,
        request_id=request_id or get_request_id(),
        trace_id=trace_id,
        span_id=span_id,
        vpn_session_id=vpn_session_id or get_vpn_session_id(),
        user_id=user_id,
        device_id=device_id,
        server_id=server_id,
        device_fingerprint=device_fingerprint,
        protocol=protocol,
        stage=stage,
        outcome=outcome,
        reason_code=reason_code,
        message=message,
        config_revision=config_revision,
        config_hash_expected=config_hash_expected,
        config_hash_actual=config_hash_actual,
        attrs_json=attrs or {},
        schema_version=1,
    )
    db.add(event)
    if commit:
        db.commit()
        db.refresh(event)
    return event


def upsert_event_dictionary(
    db: Session,
    *,
    event_name: str,
    display_name_ru: str,
    display_name_en: str,
    default_comment_template: Optional[str] = None,
    operator_hint: Optional[str] = None,
    severity_default: str = "info",
    is_active: bool = True,
    commit: bool = False,
) -> EventDictionary:
    row = db.query(EventDictionary).filter(EventDictionary.event_name == event_name).first()
    if row is None:
        row = EventDictionary(
            event_name=event_name,
            display_name_ru=display_name_ru,
            display_name_en=display_name_en,
            default_comment_template=default_comment_template,
            operator_hint=operator_hint,
            severity_default=severity_default,
            is_active=is_active,
        )
        db.add(row)
    else:
        row.display_name_ru = display_name_ru
        row.display_name_en = display_name_en
        row.default_comment_template = default_comment_template
        row.operator_hint = operator_hint
        row.severity_default = severity_default
        row.is_active = is_active
    if commit:
        db.commit()
        db.refresh(row)
    return row

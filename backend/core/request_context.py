"""
Сквозной request id для логов: клиент X-Request-ID → nginx → FastAPI.
Используется logging.Filter + ContextVar (один asyncio-task на запрос).
"""
from __future__ import annotations

import contextvars
import logging
import re
import uuid
from typing import Callable

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response

_request_id_ctx: contextvars.ContextVar[str] = contextvars.ContextVar(
    "request_id", default="-"
)
_vpn_session_id_ctx: contextvars.ContextVar[str] = contextvars.ContextVar(
    "vpn_session_id", default="-"
)

# Безопасная длина для заголовка и логов
_MAX_RID_LEN = 128
_RID_SAFE = re.compile(r"^[a-zA-Z0-9\-_.:@]+$")


def get_request_id() -> str:
    return _request_id_ctx.get()


def get_vpn_session_id() -> str:
    return _vpn_session_id_ctx.get()


def _normalize_incoming_request_id(raw: str | None) -> str | None:
    if not raw:
        return None
    s = raw.strip()
    if not s or len(s) > _MAX_RID_LEN:
        return None
    if not _RID_SAFE.match(s):
        return None
    return s


class RequestIdFilter(logging.Filter):
    """Добавляет поле request_id в LogRecord (для Formatter с %(request_id)s)."""

    def filter(self, record: logging.LogRecord) -> bool:
        record.request_id = get_request_id()
        record.vpn_session_id = get_vpn_session_id()
        return True


class RequestIdMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        incoming = (
            request.headers.get("x-request-id")
            or request.headers.get("X-Request-ID")
        )
        incoming_vpn_session = (
            request.headers.get("x-vpn-session-id")
            or request.headers.get("X-VPN-Session-ID")
        )
        rid = _normalize_incoming_request_id(incoming) or str(uuid.uuid4())
        vpn_session_id = (
            _normalize_incoming_request_id(incoming_vpn_session)
            or str(uuid.uuid4())
        )
        request.state.request_id = rid
        request.state.vpn_session_id = vpn_session_id
        token = _request_id_ctx.set(rid)
        session_token = _vpn_session_id_ctx.set(vpn_session_id)
        try:
            response = await call_next(request)
            response.headers["X-Request-ID"] = rid
            response.headers["X-VPN-Session-ID"] = vpn_session_id
            return response
        finally:
            _request_id_ctx.reset(token)
            _vpn_session_id_ctx.reset(session_token)


def attach_request_id_filter_to_root_logger() -> None:
    """Фильтр на каждом handler'е root: дочерние логгеры не проходят через root.filters."""
    from core.config import settings
    from core.log_formatters import JsonLinesFormatter

    root = logging.getLogger()
    text_fmt = (
        "%(asctime)s - %(name)s - %(levelname)s - "
        "[rid=%(request_id)s sid=%(vpn_session_id)s] %(message)s"
    )
    for h in root.handlers:
        if not any(isinstance(f, RequestIdFilter) for f in h.filters):
            h.addFilter(RequestIdFilter())
        if isinstance(h, logging.FileHandler):
            if getattr(settings, "backend_log_json", False):
                h.setFormatter(JsonLinesFormatter())
            else:
                h.setFormatter(logging.Formatter(text_fmt))
        else:
            h.setFormatter(logging.Formatter(text_fmt))

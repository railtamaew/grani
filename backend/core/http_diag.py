"""Краткая диагностика HTTP-запроса для сопоставления с nginx access log (rid, client, UA)."""
from __future__ import annotations

from starlette.requests import Request


def format_request_diag(request: Request) -> str:
    rid = (
        request.headers.get("X-Request-ID")
        or request.headers.get("x-request-id")
        or "-"
    )
    xff_raw = request.headers.get("x-forwarded-for") or request.headers.get("X-Forwarded-For") or ""
    xff_first = xff_raw.split(",")[0].strip() if xff_raw else "-"
    direct = request.client.host if request.client else "-"
    ua = (request.headers.get("user-agent") or "")[:160].replace("\n", " ").replace("\r", " ")
    return f"req_id={rid} peer={direct} xff_first={xff_first or '-'} ua={ua!r}"

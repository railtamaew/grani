"""Форматтеры логов (JSON lines для агрегаторов)."""
from __future__ import annotations

import json
import logging
from datetime import datetime, timezone


class JsonLinesFormatter(logging.Formatter):
    """Одна строка JSON на запись; поля совместимы с фильтром request_id."""

    def format(self, record: logging.LogRecord) -> str:
        rid = getattr(record, "request_id", "-")
        sid = getattr(record, "vpn_session_id", "-")
        payload = {
            "ts": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "level": record.levelname,
            "logger": record.name,
            "request_id": rid,
            "vpn_session_id": sid,
            "message": record.getMessage(),
        }
        if record.exc_info:
            payload["exc_info"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=False) + "\n"

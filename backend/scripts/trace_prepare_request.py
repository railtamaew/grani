#!/usr/bin/env python3
"""
Read-only helper: show prepare/apply hash trace by request_id.

Usage:
  cd /opt/grani/backend && PYTHONPATH=/opt/grani/backend python3 scripts/trace_prepare_request.py --request-id <RID>
"""

from __future__ import annotations

import argparse
import os
import sys

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_BACKEND_ROOT = os.path.abspath(os.path.join(_SCRIPT_DIR, ".."))
if _BACKEND_ROOT not in sys.path:
    sys.path.insert(0, _BACKEND_ROOT)

import script_env  # noqa: E402

script_env.ensure_script_environment()

from core.database import SessionLocal  # noqa: E402
from models.observability import ObservabilityEvent  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description="Trace prepare fingerprint/hash by request_id")
    parser.add_argument("--request-id", required=True, help="request_id from nginx/api logs")
    parser.add_argument("--limit", type=int, default=50, help="max rows")
    args = parser.parse_args()

    rid = (args.request_id or "").strip()
    if not rid:
        print("request_id is required", file=sys.stderr)
        return 2

    limit = max(1, min(args.limit, 200))
    db = SessionLocal()
    try:
        rows = (
            db.query(ObservabilityEvent)
            .filter(ObservabilityEvent.request_id == rid)
            .order_by(ObservabilityEvent.event_time.desc(), ObservabilityEvent.id.desc())
            .limit(limit)
            .all()
        )
        if not rows:
            print(f"No observability events for request_id={rid}")
            return 0

        print(f"request_id={rid} rows={len(rows)}")
        print("-" * 120)
        for row in rows:
            attrs = row.attrs_json or {}
            expected = (row.config_hash_expected or row.config_revision or "").strip()
            actual = (row.config_hash_actual or "").strip()
            status = "unknown"
            if expected and actual:
                status = "match" if expected == actual else "mismatch"
            print(
                f"{row.event_time} id={row.id} event={row.event_name} protocol={row.protocol} "
                f"status={status} expected={attrs.get('payload_fingerprint') or expected} "
                f"actual={attrs.get('active_config_hash') or actual}"
            )
    finally:
        db.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

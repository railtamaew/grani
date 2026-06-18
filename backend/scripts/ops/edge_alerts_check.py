#!/usr/bin/env python3
"""
SQL-based edge-agent alerts with optional Telegram delivery.

Checks:
- heartbeat stale/missing for edge-enabled servers
- stale pending/dispatched assignments
- failed assignments in recent time window
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, List, Tuple
from urllib.error import URLError
from urllib.request import Request, urlopen

from sqlalchemy import create_engine, text


@dataclass
class AlertData:
    heartbeat_stale: List[Dict[str, Any]]
    pending_stale: List[Dict[str, Any]]
    dispatched_stale: List[Dict[str, Any]]
    recent_failed: List[Dict[str, Any]]

    def has_alerts(self) -> bool:
        return any(
            (
                self.heartbeat_stale,
                self.pending_stale,
                self.dispatched_stale,
                self.recent_failed,
            )
        )

    def to_summary(self) -> Dict[str, int]:
        return {
            "heartbeat_stale": len(self.heartbeat_stale),
            "pending_stale": len(self.pending_stale),
            "dispatched_stale": len(self.dispatched_stale),
            "recent_failed": len(self.recent_failed),
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Edge alerts check (SQL + Telegram)")
    parser.add_argument("--database-url", default=os.getenv("DATABASE_URL"), help="PostgreSQL connection URL")
    parser.add_argument(
        "--heartbeat-stale-sec",
        type=int,
        default=int(os.getenv("EDGE_ALERT_HEARTBEAT_STALE_SEC", "180")),
        help="Alert threshold for stale/missing heartbeat",
    )
    parser.add_argument(
        "--pending-stale-sec",
        type=int,
        default=int(os.getenv("EDGE_ALERT_PENDING_STALE_SEC", "300")),
        help="Alert threshold for old pending assignments",
    )
    parser.add_argument(
        "--dispatched-stale-sec",
        type=int,
        default=int(os.getenv("EDGE_ALERT_DISPATCHED_STALE_SEC", "900")),
        help="Alert threshold for old dispatched assignments",
    )
    parser.add_argument(
        "--failed-window-sec",
        type=int,
        default=int(os.getenv("EDGE_ALERT_FAILED_WINDOW_SEC", "900")),
        help="Time window for failed assignments",
    )
    parser.add_argument(
        "--state-file",
        default=os.getenv("EDGE_ALERT_STATE_FILE", "/tmp/edge-alerts-state.json"),
        help="State file path for dedup/recovery alerts",
    )
    parser.add_argument("--dry-run", action="store_true", help="Do not send Telegram or update state")
    parser.add_argument("--verbose", action="store_true", help="Print detailed matched rows")
    return parser.parse_args()


def get_engine(database_url: str):
    return create_engine(database_url, future=True, pool_pre_ping=True)


def _dt_to_iso(val: Any) -> str | None:
    if val is None:
        return None
    if isinstance(val, datetime):
        if val.tzinfo is None:
            return val.replace(tzinfo=timezone.utc).isoformat()
        return val.astimezone(timezone.utc).isoformat()
    return str(val)


def collect_alerts(
    engine,
    heartbeat_stale_sec: int,
    pending_stale_sec: int,
    dispatched_stale_sec: int,
    failed_window_sec: int,
) -> AlertData:
    now = datetime.utcnow()
    hb_deadline = now - timedelta(seconds=heartbeat_stale_sec)
    pending_deadline = now - timedelta(seconds=pending_stale_sec)
    dispatched_deadline = now - timedelta(seconds=dispatched_stale_sec)
    failed_since = now - timedelta(seconds=failed_window_sec)

    with engine.connect() as conn:
        heartbeat_rows = conn.execute(
            text(
                """
                SELECT id, name, ip_address, edge_last_heartbeat_at, edge_agent_version
                FROM servers
                WHERE edge_agent_token_hash IS NOT NULL
                  AND (edge_last_heartbeat_at IS NULL OR edge_last_heartbeat_at < :deadline)
                ORDER BY id
                """
            ),
            {"deadline": hb_deadline},
        ).mappings().all()

        pending_rows = conn.execute(
            text(
                """
                SELECT id, server_id, assignment_type, status, created_at
                FROM edge_node_assignments
                WHERE status = 'pending'
                  AND created_at < :deadline
                ORDER BY created_at
                """
            ),
            {"deadline": pending_deadline},
        ).mappings().all()

        dispatched_rows = conn.execute(
            text(
                """
                SELECT id, server_id, assignment_type, status, dispatched_at, created_at
                FROM edge_node_assignments
                WHERE status = 'dispatched'
                  AND completed_at IS NULL
                  AND COALESCE(dispatched_at, created_at) < :deadline
                ORDER BY COALESCE(dispatched_at, created_at)
                """
            ),
            {"deadline": dispatched_deadline},
        ).mappings().all()

        failed_rows = conn.execute(
            text(
                """
                SELECT id, server_id, status, result_status, result_message, completed_at, created_at
                FROM edge_node_assignments
                WHERE (
                    status = 'failed'
                    OR (result_status IS NOT NULL AND result_status <> 'ok')
                )
                  AND COALESCE(completed_at, created_at) >= :since
                ORDER BY COALESCE(completed_at, created_at) DESC
                """
            ),
            {"since": failed_since},
        ).mappings().all()

    heartbeat = [
        {
            "id": r["id"],
            "name": r["name"],
            "ip_address": r["ip_address"],
            "edge_last_heartbeat_at": _dt_to_iso(r["edge_last_heartbeat_at"]),
            "edge_agent_version": r["edge_agent_version"],
        }
        for r in heartbeat_rows
    ]
    pending = [
        {
            "id": r["id"],
            "server_id": r["server_id"],
            "assignment_type": r["assignment_type"],
            "created_at": _dt_to_iso(r["created_at"]),
        }
        for r in pending_rows
    ]
    dispatched = [
        {
            "id": r["id"],
            "server_id": r["server_id"],
            "assignment_type": r["assignment_type"],
            "dispatched_at": _dt_to_iso(r["dispatched_at"]),
            "created_at": _dt_to_iso(r["created_at"]),
        }
        for r in dispatched_rows
    ]
    failed = [
        {
            "id": r["id"],
            "server_id": r["server_id"],
            "status": r["status"],
            "result_status": r["result_status"],
            "result_message": (r["result_message"] or "")[:300],
            "completed_at": _dt_to_iso(r["completed_at"]),
            "created_at": _dt_to_iso(r["created_at"]),
        }
        for r in failed_rows
    ]
    return AlertData(
        heartbeat_stale=heartbeat,
        pending_stale=pending,
        dispatched_stale=dispatched,
        recent_failed=failed,
    )


def build_fingerprint(alerts: AlertData) -> str:
    payload = {
        "heartbeat_stale": sorted([r["id"] for r in alerts.heartbeat_stale]),
        "pending_stale": sorted([r["id"] for r in alerts.pending_stale]),
        "dispatched_stale": sorted([r["id"] for r in alerts.dispatched_stale]),
        "recent_failed": sorted([r["id"] for r in alerts.recent_failed]),
    }
    raw = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def load_state(path: Path) -> Dict[str, Any]:
    if not path.exists():
        return {"last_status": "ok", "last_fingerprint": ""}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {"last_status": "ok", "last_fingerprint": ""}


def save_state(path: Path, state: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, ensure_ascii=True, indent=2), encoding="utf-8")


def format_alert_message(alerts: AlertData, host_tag: str) -> str:
    summary = alerts.to_summary()
    lines = [
        f"[EDGE ALERT] {host_tag}",
        f"- heartbeat_stale: {summary['heartbeat_stale']}",
        f"- pending_stale: {summary['pending_stale']}",
        f"- dispatched_stale: {summary['dispatched_stale']}",
        f"- recent_failed: {summary['recent_failed']}",
    ]
    if alerts.heartbeat_stale:
        sample = ", ".join([f"{r['id']}:{r['name']}" for r in alerts.heartbeat_stale[:5]])
        lines.append(f"- stale_nodes: {sample}")
    if alerts.pending_stale:
        sample = ", ".join([r["id"] for r in alerts.pending_stale[:5]])
        lines.append(f"- pending_ids: {sample}")
    if alerts.dispatched_stale:
        sample = ", ".join([r["id"] for r in alerts.dispatched_stale[:5]])
        lines.append(f"- dispatched_ids: {sample}")
    if alerts.recent_failed:
        sample = ", ".join([r["id"] for r in alerts.recent_failed[:5]])
        lines.append(f"- failed_ids: {sample}")
    return "\n".join(lines)


def format_recovery_message(host_tag: str) -> str:
    return f"[EDGE RECOVERY] {host_tag}\n- edge alerts normalized"


def send_telegram_message(token: str, chat_id: str, message: str, timeout_sec: int = 10) -> Tuple[bool, str]:
    if not token or not chat_id:
        return (False, "telegram credentials missing")
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    payload = json.dumps(
        {
            "chat_id": chat_id,
            "text": message,
            "disable_web_page_preview": True,
        }
    ).encode("utf-8")
    request = Request(url, data=payload, headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urlopen(request, timeout=timeout_sec) as response:
            body = response.read().decode("utf-8", errors="ignore")
            if response.status != 200:
                return (False, f"http_status={response.status} body={body[:300]}")
            return (True, "ok")
    except URLError as exc:
        return (False, f"telegram_error={exc}")


def main() -> int:
    args = parse_args()
    if not args.database_url:
        print("ERROR: DATABASE_URL is required (or --database-url).", file=sys.stderr)
        return 2

    state_path = Path(args.state_file)
    telegram_token = os.getenv("TELEGRAM_BOT_TOKEN", "")
    telegram_chat_id = os.getenv("TELEGRAM_CHAT_ID", "")
    host_tag = os.getenv("EDGE_ALERT_HOST_TAG", os.getenv("HOSTNAME", "grani-edge"))

    try:
        engine = get_engine(args.database_url)
        alerts = collect_alerts(
            engine=engine,
            heartbeat_stale_sec=args.heartbeat_stale_sec,
            pending_stale_sec=args.pending_stale_sec,
            dispatched_stale_sec=args.dispatched_stale_sec,
            failed_window_sec=args.failed_window_sec,
        )
    except Exception as exc:
        print(f"ERROR: edge check runtime failure: {exc}", file=sys.stderr)
        return 2

    summary = alerts.to_summary()
    print(f"edge_alerts summary: {json.dumps(summary, ensure_ascii=True, sort_keys=True)}")
    if args.verbose:
        print(
            json.dumps(
                {
                    "heartbeat_stale": alerts.heartbeat_stale,
                    "pending_stale": alerts.pending_stale,
                    "dispatched_stale": alerts.dispatched_stale,
                    "recent_failed": alerts.recent_failed,
                },
                ensure_ascii=True,
                indent=2,
            )
        )

    current_is_alert = alerts.has_alerts()
    current_fingerprint = build_fingerprint(alerts) if current_is_alert else ""
    prev_state = load_state(state_path)
    prev_status = prev_state.get("last_status", "ok")
    prev_fingerprint = prev_state.get("last_fingerprint", "")

    should_send_alert = current_is_alert and (prev_status != "alert" or prev_fingerprint != current_fingerprint)
    should_send_recovery = (not current_is_alert) and prev_status == "alert"

    if args.dry_run:
        print(
            f"dry_run decision: send_alert={should_send_alert} "
            f"send_recovery={should_send_recovery} state_write=false"
        )
        return 1 if current_is_alert else 0

    if should_send_alert:
        message = format_alert_message(alerts, host_tag)
        ok, reason = send_telegram_message(telegram_token, telegram_chat_id, message)
        print(f"telegram alert send: ok={ok} reason={reason}")
    elif should_send_recovery:
        message = format_recovery_message(host_tag)
        ok, reason = send_telegram_message(telegram_token, telegram_chat_id, message)
        print(f"telegram recovery send: ok={ok} reason={reason}")
    else:
        print("telegram send skipped: no state change")

    new_state = {
        "last_status": "alert" if current_is_alert else "ok",
        "last_fingerprint": current_fingerprint,
        "updated_at_utc": datetime.now(timezone.utc).isoformat(),
        "summary": summary,
    }
    save_state(state_path, new_state)

    return 1 if current_is_alert else 0


if __name__ == "__main__":
    raise SystemExit(main())

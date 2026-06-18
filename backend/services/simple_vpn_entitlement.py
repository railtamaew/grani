"""Entitlement enforcement for the Simple VPN / GRANIwg path."""
import logging
from typing import Any, Dict

from sqlalchemy import text
from sqlalchemy.orm import Session

from core.cache import cache_delete, invalidate_user_cache
from models.server import Server
from models.user import Device
from services.wireguard_manager import WireGuardManager

logger = logging.getLogger(__name__)


def ensure_device_server_peers_entitlement_columns(db: Session) -> None:
    db.execute(text("""
        CREATE TABLE IF NOT EXISTS device_server_peers (
            id SERIAL PRIMARY KEY,
            device_id INTEGER NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
            server_id INTEGER NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
            protocol VARCHAR(32) NOT NULL DEFAULT 'graniwg',
            public_key VARCHAR NOT NULL,
            vpn_ip VARCHAR NOT NULL,
            config_revision VARCHAR,
            created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW(),
            updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW(),
            last_used_at TIMESTAMP WITHOUT TIME ZONE,
            revoked_at TIMESTAMP WITHOUT TIME ZONE,
            UNIQUE (device_id, server_id, protocol)
        )
    """))
    db.execute(text("""
        CREATE INDEX IF NOT EXISTS ix_device_server_peers_device_protocol
        ON device_server_peers (device_id, protocol)
    """))
    db.execute(text("""
        CREATE INDEX IF NOT EXISTS ix_device_server_peers_server_public_key
        ON device_server_peers (server_id, public_key)
    """))
    db.execute(text("""
        ALTER TABLE device_server_peers
        ADD COLUMN IF NOT EXISTS suspended_at TIMESTAMP WITHOUT TIME ZONE
    """))
    db.execute(text("""
        ALTER TABLE device_server_peers
        ADD COLUMN IF NOT EXISTS suspend_reason VARCHAR(64)
    """))
    db.execute(text("""
        ALTER TABLE device_server_peers
        ADD COLUMN IF NOT EXISTS revoked_reason VARCHAR(64)
    """))
    db.execute(text("""
        ALTER TABLE device_server_peers
        ADD COLUMN IF NOT EXISTS preshared_key VARCHAR
    """))
    db.execute(text("""
        CREATE INDEX IF NOT EXISTS ix_device_server_peers_suspended
        ON device_server_peers (suspended_at)
    """))


def suspend_user_graniwg_access(
    db: Session,
    user_id: int,
    *,
    reason: str = "access_expired",
    hard_revoke: bool = False,
) -> Dict[str, Any]:
    """Remove live GRANIwg peers while preserving reusable profiles on soft expiry."""
    ensure_device_server_peers_entitlement_columns(db)
    rows = db.execute(
        text("""
            SELECT
                p.id,
                p.server_id,
                d.id AS device_pk_id,
                s.is_active AS server_is_active,
                s.status AS server_status
            FROM device_server_peers p
            JOIN devices d ON d.id = p.device_id
            LEFT JOIN servers s ON s.id = p.server_id
            WHERE d.user_id = :user_id
              AND p.protocol = 'graniwg'
              AND p.revoked_at IS NULL
        """),
        {"user_id": user_id},
    ).mappings().all()

    removed = 0
    failed = 0
    skipped = 0
    for row in rows:
        server_status = (row.get("server_status") or "").lower()
        server_is_active = bool(row.get("server_is_active"))
        should_touch_server = server_is_active and server_status in {"online", "draining"}
        if should_touch_server:
            device = db.query(Device).filter(Device.id == row["device_pk_id"]).first()
            server = db.query(Server).filter(Server.id == row["server_id"]).first()
            if device is None or server is None:
                skipped += 1
            else:
                try:
                    if WireGuardManager(server).remove_peer_from_server(device, server):
                        removed += 1
                    else:
                        failed += 1
                except Exception:
                    failed += 1
                    logger.exception(
                        "simple-vpn entitlement: failed to remove peer user_id=%s device_id=%s server_id=%s",
                        user_id,
                        getattr(device, "id", None),
                        getattr(server, "id", None),
                    )
        else:
            skipped += 1

        if hard_revoke:
            db.execute(
                text("""
                    UPDATE device_server_peers
                    SET suspended_at = COALESCE(suspended_at, NOW()),
                        suspend_reason = :reason,
                        revoked_at = COALESCE(revoked_at, NOW()),
                        revoked_reason = :reason,
                        updated_at = NOW()
                    WHERE id = :peer_id
                """),
                {"peer_id": row["id"], "reason": reason},
            )
        else:
            db.execute(
                text("""
                    UPDATE device_server_peers
                    SET suspended_at = COALESCE(suspended_at, NOW()),
                        suspend_reason = :reason,
                        updated_at = NOW()
                    WHERE id = :peer_id
                      AND revoked_at IS NULL
                """),
                {"peer_id": row["id"], "reason": reason},
            )

    db.execute(
        text("""
            UPDATE devices
            SET is_active = FALSE,
                is_vpn_enabled = FALSE,
                current_server_id = NULL,
                ip_address = NULL,
                vpn_protocol = NULL
            WHERE user_id = :user_id
              AND (
                  is_active = TRUE OR is_vpn_enabled = TRUE OR
                  current_server_id IS NOT NULL OR ip_address IS NOT NULL OR
                  vpn_protocol IS NOT NULL
              )
        """),
        {"user_id": user_id},
    )
    try:
        cache_delete(f"cache:devices:{user_id}")
        invalidate_user_cache(user_id)
    except Exception:
        logger.debug(
            "simple-vpn entitlement: cache invalidation failed user_id=%s",
            user_id,
            exc_info=True,
        )

    logger.warning(
        "simple-vpn entitlement suspended user_id=%s reason=%s hard_revoke=%s peers=%s removed=%s failed=%s skipped=%s",
        user_id,
        reason,
        hard_revoke,
        len(rows),
        removed,
        failed,
        skipped,
    )
    return {
        "peers": len(rows),
        "removed": removed,
        "failed": failed,
        "skipped": skipped,
        "hard_revoke": hard_revoke,
    }

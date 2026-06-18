"""
Redis pub/sub для мгновенного пробуждения long-poll apply-state между Gunicorn workers.
В pytest (PYTEST_CURRENT_TEST) ожидание по каналу отключено в API, чтобы не блокировать тесты.
"""
from __future__ import annotations

import logging
import time
logger = logging.getLogger(__name__)

CHANNEL_PREFIX = "grani:xray_apply:"


def publish_xray_apply_state(server_id: int, revision: str, status: str) -> None:
    from core.config import settings

    if getattr(settings, "cache_backend", "memory").lower() != "redis":
        return
    url = getattr(settings, "redis_url", None) or ""
    if not url:
        return
    try:
        import redis

        r = redis.from_url(url, decode_responses=True)
        try:
            r.publish(f"{CHANNEL_PREFIX}{server_id}", f"{revision}|{status}")
        finally:
            r.close()
    except Exception as e:
        logger.debug("xray apply publish skipped: %s", e)


def blocking_wait_xray_apply(
    redis_url: str, server_id: int, revision: str, timeout_sec: float
) -> bool:
    """
    Блокирует до timeout_sec, возвращает True если пришло сообщение для той же revision.
    """
    if timeout_sec <= 0 or not redis_url:
        return False
    channel = f"{CHANNEL_PREFIX}{server_id}"
    try:
        import redis

        r = redis.from_url(redis_url, decode_responses=True)
        pubsub = r.pubsub()
        try:
            pubsub.subscribe(channel)
            deadline = time.monotonic() + timeout_sec
            while time.monotonic() < deadline:
                rem = max(0.05, min(1.0, deadline - time.monotonic()))
                msg = pubsub.get_message(timeout=rem)
                if not msg:
                    continue
                if msg.get("type") != "message":
                    continue
                data = msg.get("data") or ""
                if data.startswith(f"{revision}|") or data == revision:
                    return True
            return False
        finally:
            try:
                pubsub.close()
            except Exception:
                pass
            try:
                r.close()
            except Exception:
                pass
    except Exception as e:
        logger.debug("xray apply subscribe wait skipped: %s", e)
        return False


def should_use_apply_pubsub_wait() -> bool:
    import os

    if os.environ.get("PYTEST_CURRENT_TEST"):
        return False
    from core.config import settings

    if getattr(settings, "cache_backend", "memory").lower() != "redis":
        return False
    return bool(getattr(settings, "redis_url", None) or "")

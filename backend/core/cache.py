"""
Cache layer: delegates to configurable backend (in-memory or Redis).
Public API: cache_get, cache_set, cache_delete, invalidate_user_cache, cache_clear, cache_stats.
"""
import logging
from typing import Any, Optional, Dict

from core.cache_backend import CacheBackend, InMemoryCacheBackend, RedisCacheBackend

logger = logging.getLogger(__name__)

_backend: Optional[CacheBackend] = None


def set_cache_backend(backend: Optional[CacheBackend]) -> None:
    """Set cache backend (for tests). Pass None to reset to config-based default."""
    global _backend
    _backend = backend


def _get_backend() -> CacheBackend:
    global _backend
    if _backend is not None:
        return _backend
    from core.config import settings
    if getattr(settings, "cache_backend", "memory").lower() == "redis":
        try:
            _backend = RedisCacheBackend(settings.redis_url)
        except Exception:
            logger.warning("Redis cache backend failed, falling back to memory.")
            _backend = InMemoryCacheBackend()
    else:
        _backend = InMemoryCacheBackend()
    return _backend


def cache_get(key: str) -> Optional[Any]:
    """Get value by key. Returns None if missing or expired."""
    return _get_backend().get(key)


def cache_set(key: str, value: Any, ttl: int = 300) -> None:
    """Set value with TTL in seconds (default 5 minutes). ttl=0 means no expiry."""
    _get_backend().set(key, value, ttl=ttl)


def cache_delete(key: str) -> None:
    """Delete a single key."""
    _get_backend().delete(key)


def invalidate_user_cache(
    user_id: int, *, include_session_prepare: bool = True
) -> None:
    """Invalidate user-scoped cache: user:*, devices list, and optionally session_prepare.

    After Google Play verify, keeping session_prepare avoids wiping a just-warmed Xray
    prepare cache while the user immediately taps Connect.
    """
    be = _get_backend()
    be.delete_pattern(f"user:{user_id}")
    be.delete_pattern(f"user_{user_id}")
    cache_delete(f"cache:devices:{user_id}")
    if include_session_prepare:
        be.delete_pattern(f"session_prepare:{user_id}:")
    logger.debug(
        "Cache invalidated for user_id=%s (session_prepare=%s)",
        user_id,
        "yes" if include_session_prepare else "skipped",
    )


def cache_clear() -> None:
    """Clear all cache (only for in-memory backend; Redis not cleared by design)."""
    be = _get_backend()
    if isinstance(be, InMemoryCacheBackend):
        be._store.clear()
        logger.debug("In-memory cache cleared.")
    else:
        logger.debug("cache_clear() called with non-memory backend; no-op.")


def cache_stats() -> Dict[str, Any]:
    """Return cache statistics. For Redis, returns placeholder; for memory returns counts."""
    be = _get_backend()
    if isinstance(be, InMemoryCacheBackend):
        total = len(be._store)
        import time
        expired = sum(
            1 for item in be._store.values()
            if item.get("expires_at") and time.time() > item["expires_at"]
        )
        return {
            "total_items": total,
            "expired_items": expired,
            "active_items": total - expired,
        }
    return {"backend": "redis", "total_items": None, "active_items": None}

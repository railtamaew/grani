"""
Cache backend abstraction: interface and implementations (in-memory, Redis).
Allows switching cache storage via config for single-process vs multi-worker setups.
"""
import pickle
import time
import logging
from abc import ABC, abstractmethod
from typing import Any, Optional

logger = logging.getLogger(__name__)


class CacheBackend(ABC):
    """Abstract cache backend interface."""

    @abstractmethod
    def get(self, key: str) -> Optional[Any]:
        """Get value by key. Returns None if missing or expired."""
        pass

    @abstractmethod
    def set(self, key: str, value: Any, ttl: int = 300) -> None:
        """Set value with optional TTL in seconds. ttl=0 means no expiry."""
        pass

    @abstractmethod
    def delete(self, key: str) -> None:
        """Delete a single key."""
        pass

    @abstractmethod
    def delete_pattern(self, prefix: str) -> None:
        """Delete all keys that start with the given prefix."""
        pass


class InMemoryCacheBackend(CacheBackend):
    """In-process cache. Not shared across workers."""

    def __init__(self) -> None:
        self._store: dict[str, dict[str, Any]] = {}

    def get(self, key: str) -> Optional[Any]:
        if key not in self._store:
            return None
        item = self._store[key]
        expires_at = item.get("expires_at")
        if expires_at is not None and time.time() > expires_at:
            del self._store[key]
            return None
        return item.get("value")

    def set(self, key: str, value: Any, ttl: int = 300) -> None:
        expires_at = (time.time() + ttl) if ttl > 0 else None
        self._store[key] = {"value": value, "expires_at": expires_at}
        logger.debug("Cache set: %s (TTL: %ss)", key, ttl)

    def delete(self, key: str) -> None:
        if key in self._store:
            del self._store[key]
            logger.debug("Cache deleted: %s", key)

    def delete_pattern(self, prefix: str) -> None:
        to_delete = [k for k in self._store if k.startswith(prefix)]
        for k in to_delete:
            del self._store[k]
        if to_delete:
            logger.debug("Cache deleted by prefix %s: %s keys", prefix, len(to_delete))


class RedisCacheBackend(CacheBackend):
    """Redis-backed cache. Shared across workers. Uses pickle for values."""

    def __init__(self, redis_url: str) -> None:
        try:
            import redis
            self._client = redis.from_url(redis_url, decode_responses=False)
            self._client.ping()
        except Exception as e:
            logger.warning("Redis unavailable for cache: %s. Use CACHE_BACKEND=memory or fix redis_url.", e)
            raise
        self._prefix = "grani:cache:"

    def _key(self, key: str) -> str:
        return self._prefix + key

    def get(self, key: str) -> Optional[Any]:
        try:
            raw = self._client.get(self._key(key))
        except Exception as e:
            logger.warning("Redis cache get failed for %s: %s", key, e)
            return None
        if raw is None:
            return None
        try:
            return pickle.loads(raw)
        except Exception as e:
            logger.warning("Redis cache unpickle failed for %s: %s", key, e)
            return None

    def set(self, key: str, value: Any, ttl: int = 300) -> None:
        try:
            data = pickle.dumps(value)
            k = self._key(key)
            self._client.set(k, data)
            if ttl > 0:
                self._client.expire(k, ttl)
            logger.debug("Redis cache set: %s (TTL: %ss)", key, ttl)
        except Exception as e:
            logger.warning("Redis cache set failed for %s: %s", key, e)

    def delete(self, key: str) -> None:
        try:
            self._client.delete(self._key(key))
            logger.debug("Redis cache deleted: %s", key)
        except Exception as e:
            logger.warning("Redis cache delete failed for %s: %s", key, e)

    def delete_pattern(self, prefix: str) -> None:
        full_prefix = self._key(prefix)
        try:
            cursor = 0
            deleted = 0
            while True:
                cursor, keys = self._client.scan(cursor=cursor, match=full_prefix + "*", count=100)
                if keys:
                    self._client.delete(*keys)
                    deleted += len(keys)
                if cursor == 0:
                    break
            if deleted:
                logger.debug("Redis cache deleted by prefix %s: %s keys", prefix, deleted)
        except Exception as e:
            logger.warning("Redis cache delete_pattern failed for %s: %s", prefix, e)

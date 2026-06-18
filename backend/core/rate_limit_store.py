"""
Rate limit store abstraction: in-memory (per process) or Redis (shared across workers).
"""
import logging
import uuid
from abc import ABC, abstractmethod
from datetime import datetime
from typing import Optional

logger = logging.getLogger(__name__)


class RateLimitStore(ABC):
    """Abstract store for rate limit timestamps."""

    @abstractmethod
    def add_timestamp(self, key: str, period_seconds: int) -> None:
        """Record current time for key. Period may be used for TTL/cleanup."""
        pass

    @abstractmethod
    def count_recent(self, key: str, period_seconds: int) -> int:
        """Return number of timestamps recorded for key within the last period_seconds."""
        pass

    def get_oldest_timestamp(self, key: str, period_seconds: int) -> Optional[float]:
        """Return oldest timestamp in the window, or None. Used for reset_at."""
        return None


class InMemoryRateLimitStore(RateLimitStore):
    """In-process store. Not shared across workers."""

    def __init__(self) -> None:
        self._store: dict[str, list[float]] = {}

    def add_timestamp(self, key: str, period_seconds: int) -> None:
        now = datetime.now().timestamp()
        if key not in self._store:
            self._store[key] = []
        self._store[key].append(now)

    def count_recent(self, key: str, period_seconds: int) -> int:
        now = datetime.now().timestamp()
        cutoff = now - period_seconds
        if key not in self._store:
            return 0
        # Trim old entries and return count
        self._store[key] = [t for t in self._store[key] if t > cutoff]
        return len(self._store[key])

    def get_oldest_timestamp(self, key: str, period_seconds: int) -> Optional[float]:
        if key not in self._store or not self._store[key]:
            return None
        now = datetime.now().timestamp()
        cutoff = now - period_seconds
        recent = [t for t in self._store[key] if t > cutoff]
        return min(recent) if recent else None


class RedisRateLimitStore(RateLimitStore):
    """Redis-backed store. Shared across workers. Uses sorted set by timestamp."""

    def __init__(self, redis_url: str) -> None:
        try:
            import redis
            self._client = redis.from_url(redis_url, decode_responses=False)
            self._client.ping()
        except Exception as e:
            logger.warning("Redis unavailable for rate limit: %s. Use RATE_LIMIT_STORE=memory.", e)
            raise
        self._prefix = "grani:ratelimit:"

    def _key(self, key: str) -> str:
        return self._prefix + key.replace(" ", "_")

    def add_timestamp(self, key: str, period_seconds: int) -> None:
        try:
            now = datetime.now().timestamp()
            rkey = self._key(key)
            member = f"{now}_{uuid.uuid4().hex}"
            self._client.zadd(rkey, {member: now})
            self._client.expire(rkey, period_seconds + 1)
        except Exception as e:
            logger.warning("Redis rate limit add_timestamp failed for %s: %s", key, e)

    def count_recent(self, key: str, period_seconds: int) -> int:
        try:
            now = datetime.now().timestamp()
            cutoff = now - period_seconds
            rkey = self._key(key)
            # Remove old entries and count
            self._client.zremrangebyscore(rkey, "-inf", str(cutoff))
            return self._client.zcard(rkey)
        except Exception as e:
            logger.warning("Redis rate limit count_recent failed for %s: %s", key, e)
            return 0

    def get_oldest_timestamp(self, key: str, period_seconds: int) -> Optional[float]:
        try:
            now = datetime.now().timestamp()
            cutoff = now - period_seconds
            rkey = self._key(key)
            self._client.zremrangebyscore(rkey, "-inf", str(cutoff))
            result = self._client.zrange(rkey, 0, 0, withscores=True)
            if result:
                return float(result[0][1])
            return None
        except Exception as e:
            logger.warning("Redis rate limit get_oldest_timestamp failed for %s: %s", key, e)
            return None


def get_rate_limit_store(store_type: str = "memory", redis_url: Optional[str] = None) -> RateLimitStore:
    """Factory: returns InMemoryRateLimitStore or RedisRateLimitStore."""
    if store_type and store_type.lower() == "redis" and redis_url:
        try:
            return RedisRateLimitStore(redis_url)
        except Exception:
            return InMemoryRateLimitStore()
    return InMemoryRateLimitStore()

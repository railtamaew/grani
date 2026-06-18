"""
Unit tests for cache backends (InMemory, Redis when available).
"""
import pytest
import time
from core.cache_backend import InMemoryCacheBackend, RedisCacheBackend
from core.cache import (
    cache_get,
    cache_set,
    cache_delete,
    invalidate_user_cache,
    set_cache_backend,
)


class TestInMemoryCacheBackend:
    """Tests for InMemoryCacheBackend."""

    def test_get_missing_returns_none(self):
        backend = InMemoryCacheBackend()
        assert backend.get("nonexistent") is None

    def test_set_and_get(self):
        backend = InMemoryCacheBackend()
        backend.set("k1", "v1", ttl=60)
        assert backend.get("k1") == "v1"

    def test_set_and_get_dict(self):
        backend = InMemoryCacheBackend()
        backend.set("k", {"a": 1, "b": 2}, ttl=60)
        assert backend.get("k") == {"a": 1, "b": 2}

    def test_ttl_expiry(self):
        backend = InMemoryCacheBackend()
        backend.set("short", "x", ttl=1)
        assert backend.get("short") == "x"
        time.sleep(1.1)
        assert backend.get("short") is None

    def test_delete(self):
        backend = InMemoryCacheBackend()
        backend.set("k", "v", ttl=60)
        backend.delete("k")
        assert backend.get("k") is None

    def test_delete_pattern(self):
        backend = InMemoryCacheBackend()
        backend.set("user:1:a", 1, ttl=60)
        backend.set("user:1:b", 2, ttl=60)
        backend.set("user:2:x", 3, ttl=60)
        backend.delete_pattern("user:1")
        assert backend.get("user:1:a") is None
        assert backend.get("user:1:b") is None
        assert backend.get("user:2:x") == 3


class TestCacheModuleWithBackend:
    """Tests for core.cache public API using injected backend."""

    def test_cache_get_set_delete(self):
        set_cache_backend(InMemoryCacheBackend())
        try:
            assert cache_get("x") is None
            cache_set("x", 42, ttl=60)
            assert cache_get("x") == 42
            cache_delete("x")
            assert cache_get("x") is None
        finally:
            set_cache_backend(None)

    def test_invalidate_user_cache(self):
        set_cache_backend(InMemoryCacheBackend())
        try:
            cache_set("user:10:devices", [1, 2], ttl=60)
            cache_set("user_10:pref", "y", ttl=60)
            cache_set("user:20:devices", [3], ttl=60)
            cache_set("cache:devices:10", [{"id": 1}], ttl=60)
            cache_set("session_prepare:10:1:dev:xray_vless", {"k": 1}, ttl=60)
            invalidate_user_cache(10)
            assert cache_get("user:10:devices") is None
            assert cache_get("user_10:pref") is None
            assert cache_get("cache:devices:10") is None
            assert cache_get("session_prepare:10:1:dev:xray_vless") is None
            assert cache_get("user:20:devices") == [3]
        finally:
            set_cache_backend(None)

    def test_invalidate_user_cache_preserves_session_prepare_when_disabled(self):
        set_cache_backend(InMemoryCacheBackend())
        try:
            cache_set("user:10:devices", [1], ttl=60)
            cache_set("session_prepare:10:1:dev:xray_vless", {"k": 1}, ttl=60)
            invalidate_user_cache(10, include_session_prepare=False)
            assert cache_get("user:10:devices") is None
            assert cache_get("session_prepare:10:1:dev:xray_vless") == {"k": 1}
        finally:
            set_cache_backend(None)


@pytest.mark.redis
class TestRedisCacheBackend:
    """Tests for RedisCacheBackend. Skip if Redis unavailable."""

    @pytest.fixture
    def redis_backend(self, redis_cache_backend):
        return redis_cache_backend

    def test_set_and_get(self, redis_backend):
        redis_backend.set("tk1", "v1", ttl=10)
        assert redis_backend.get("tk1") == "v1"

    def test_get_missing_returns_none(self, redis_backend):
        assert redis_backend.get("nonexistent_key_xyz") is None

    def test_delete(self, redis_backend):
        redis_backend.set("tk2", "v2", ttl=10)
        redis_backend.delete("tk2")
        assert redis_backend.get("tk2") is None

    def test_delete_pattern(self, redis_backend):
        redis_backend.set("user:100:a", 1, ttl=10)
        redis_backend.set("user:100:b", 2, ttl=10)
        redis_backend.set("user:101:x", 3, ttl=10)
        redis_backend.delete_pattern("user:100")
        assert redis_backend.get("user:100:a") is None
        assert redis_backend.get("user:100:b") is None
        assert redis_backend.get("user:101:x") == 3

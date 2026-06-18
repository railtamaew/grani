"""
Tests for rate limiting: store and RateLimiter.
"""
from unittest.mock import MagicMock

from core.rate_limit_store import InMemoryRateLimitStore
from middleware.rate_limit import RateLimiter


class TestInMemoryRateLimitStore:
    def test_add_and_count(self):
        store = InMemoryRateLimitStore()
        store.add_timestamp("k1", 60)
        store.add_timestamp("k1", 60)
        assert store.count_recent("k1", 60) == 2

    def test_count_recent_after_period(self):
        store = InMemoryRateLimitStore()
        store.add_timestamp("k", 60)
        assert store.count_recent("k", 60) == 1
        # Simulate time passing by adding old timestamp (we can't easily mock time in store)
        store._store["k"].append(store._store["k"][0] - 70)  # 70 sec ago
        assert store.count_recent("k", 60) == 1  # old one trimmed

    def test_get_oldest_timestamp(self):
        store = InMemoryRateLimitStore()
        store.add_timestamp("k", 60)
        store.add_timestamp("k", 60)
        oldest = store.get_oldest_timestamp("k", 60)
        assert oldest is not None
        assert store.count_recent("k", 60) == 2


class TestRateLimiterWithStore:
    def test_under_limit_allowed(self):
        store = InMemoryRateLimitStore()
        limiter = RateLimiter(calls=3, period=60, store=store)
        req = MagicMock()
        req.client = MagicMock(host="127.0.0.1")
        req.url = MagicMock(path="/test")
        assert limiter.check_rate_limit(req) is True
        assert limiter.check_rate_limit(req) is True
        assert limiter.check_rate_limit(req) is True

    def test_over_limit_denied(self):
        store = InMemoryRateLimitStore()
        limiter = RateLimiter(calls=2, period=60, store=store)
        req = MagicMock()
        req.client = MagicMock(host="127.0.0.2")
        req.url = type("URL", (), {"path": "/test"})()
        assert limiter.check_rate_limit(req) is True
        assert limiter.check_rate_limit(req) is True
        assert limiter.check_rate_limit(req) is False
        assert limiter.get_remaining(req) == 0

    def test_remaining_decreases(self):
        store = InMemoryRateLimitStore()
        limiter = RateLimiter(calls=5, period=60, store=store)
        req = MagicMock()
        req.client = MagicMock(host="127.0.0.3")
        req.url = type("URL", (), {"path": "/test"})()
        assert limiter.get_remaining(req) == 5
        limiter.check_rate_limit(req)
        assert limiter.get_remaining(req) == 4

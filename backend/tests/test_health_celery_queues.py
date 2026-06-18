"""Тесты check_celery_queues (Redis LLEN)."""
from unittest.mock import MagicMock, patch

import pytest

from services.health_service import HealthService


@pytest.fixture
def mock_redis():
    client = MagicMock()
    client.ping.return_value = True
    client.llen.side_effect = lambda name: {"default": 2, "vpn": 1, "monitoring": 0, "celery": 0}[name]
    return client


def test_check_celery_queues_ok(mock_redis):
    with patch("redis.from_url", return_value=mock_redis):
        out = HealthService.check_celery_queues()
    assert out["status"] == "healthy"
    assert out["total_pending"] == 3
    assert out["depths"]["default"] == 2


def test_check_celery_queues_degraded_total():
    client = MagicMock()
    client.ping.return_value = True
    client.llen.side_effect = lambda name: 300

    with patch("redis.from_url", return_value=client):
        out = HealthService.check_celery_queues()
    assert out["status"] == "degraded"
    assert out["total_pending"] == 1200


def test_check_celery_queues_redis_down():
    with patch("redis.from_url", side_effect=ConnectionError("refused")):
        out = HealthService.check_celery_queues()
    assert out["status"] == "degraded"
    assert "message" in out

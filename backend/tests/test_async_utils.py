"""Tests for core.async_utils.run_sync."""
import pytest
from core.async_utils import run_sync


@pytest.mark.asyncio
async def test_run_sync_returns_value():
    def add(a: int, b: int) -> int:
        return a + b
    result = await run_sync(add, 1, 2)
    assert result == 3


@pytest.mark.asyncio
async def test_run_sync_propagates_exception():
    def raise_err():
        raise ValueError("test")
    try:
        await run_sync(raise_err)
        assert False, "expected ValueError"
    except ValueError as e:
        assert "test" in str(e)

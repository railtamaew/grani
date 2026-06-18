"""
Run synchronous (blocking) code from async handlers without blocking the event loop.
"""
import asyncio
from typing import TypeVar, Callable, Any

T = TypeVar("T")


async def run_sync(
    sync_callable: Callable[..., T],
    *args: Any,
    **kwargs: Any,
) -> T:
    """
    Run a synchronous callable in a thread pool. Use from async endpoints
    to avoid blocking the event loop (e.g. for SSH, heavy DB, subprocess).
    """
    loop = asyncio.get_event_loop()
    return await asyncio.to_thread(
        _run_with_args,
        sync_callable,
        args,
        kwargs,
    )


def _run_with_args(
    fn: Callable[..., T],
    args: tuple,
    kwargs: dict,
) -> T:
    return fn(*args, **kwargs)

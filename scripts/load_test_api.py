import asyncio
import os
import statistics
import time
from typing import List, Tuple

import httpx


def percentile(values: List[float], p: float) -> float:
    if not values:
        return 0.0
    values = sorted(values)
    idx = int((len(values) - 1) * p)
    return values[idx]


async def run_load_test(
    base_url: str,
    path: str,
    total_requests: int,
    concurrency: int,
    headers: dict,
) -> Tuple[List[float], int]:
    latencies: List[float] = []
    errors = 0
    sem = asyncio.Semaphore(concurrency)

    async with httpx.AsyncClient(base_url=base_url, timeout=30) as client:
        async def make_request():
            nonlocal errors
            async with sem:
                start = time.perf_counter()
                try:
                    response = await client.get(path, headers=headers)
                    if response.status_code >= 400:
                        errors += 1
                except Exception:
                    errors += 1
                finally:
                    duration_ms = (time.perf_counter() - start) * 1000
                    latencies.append(duration_ms)

        tasks = [asyncio.create_task(make_request()) for _ in range(total_requests)]
        await asyncio.gather(*tasks)

    return latencies, errors


def main() -> None:
    base_url = os.getenv("API_BASE_URL", "http://localhost:8000")
    path = os.getenv("API_PATH", "/api/vpn/servers")
    total_requests = int(os.getenv("TOTAL_REQUESTS", "500"))
    concurrency = int(os.getenv("CONCURRENCY", "50"))
    token = os.getenv("API_TOKEN", "")

    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    latencies, errors = asyncio.run(
        run_load_test(base_url, path, total_requests, concurrency, headers)
    )

    if not latencies:
        print("No latencies recorded.")
        return

    p50 = percentile(latencies, 0.50)
    p95 = percentile(latencies, 0.95)
    p99 = percentile(latencies, 0.99)
    avg = statistics.mean(latencies)

    print("Load test results")
    print(f"- URL: {base_url}{path}")
    print(f"- Requests: {total_requests}")
    print(f"- Concurrency: {concurrency}")
    print(f"- Errors: {errors}")
    print(f"- Avg latency: {avg:.1f}ms")
    print(f"- P50 latency: {p50:.1f}ms")
    print(f"- P95 latency: {p95:.1f}ms")
    print(f"- P99 latency: {p99:.1f}ms")


if __name__ == "__main__":
    main()

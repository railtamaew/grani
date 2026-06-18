from __future__ import annotations

from collections import defaultdict, deque
from dataclasses import dataclass
from threading import Lock
from time import perf_counter
from typing import Any, Dict, Iterable, Optional
import math
import datetime

from core.config import settings

# Подстроки путей FastAPI (после матчинга route) для дашборда и алертов
CRITICAL_ROUTE_SUBSTRINGS: tuple[str, ...] = (
    "/api/auth/send-code",
    "/api/auth/verify-code",
    "/api/vpn/device/register",
    "/api/vpn/status",
    "/api/vpn/session/prepare",
    "/api/vpn/xray/create-client",
)


@dataclass
class _WindowStats:
    count: int
    avg_ms: float
    max_ms: float
    p50_ms: Optional[float]
    p95_ms: Optional[float]


class RollingWindow:
    def __init__(self, maxlen: int) -> None:
        self._values = deque(maxlen=maxlen)
        self._count = 0
        self._total = 0.0
        self._max = 0.0
        self._lock = Lock()

    def observe(self, value_ms: float) -> None:
        with self._lock:
            self._count += 1
            self._total += value_ms
            if value_ms > self._max:
                self._max = value_ms
            self._values.append(value_ms)

    def snapshot(self) -> _WindowStats:
        with self._lock:
            if not self._values:
                return _WindowStats(
                    count=0,
                    avg_ms=0.0,
                    max_ms=0.0,
                    p50_ms=None,
                    p95_ms=None,
                )

            values = sorted(self._values)
            count = self._count
            avg_ms = self._total / count if count else 0.0

            def percentile(p: float) -> float:
                if not values:
                    return 0.0
                idx = int(math.ceil(p * len(values))) - 1
                idx = max(0, min(idx, len(values) - 1))
                return float(values[idx])

            return _WindowStats(
                count=count,
                avg_ms=avg_ms,
                max_ms=float(self._max),
                p50_ms=percentile(0.50),
                p95_ms=percentile(0.95),
            )


class MetricsRegistry:
    def __init__(self, window_size: int = 2000) -> None:
        self._window_size = window_size
        self._request_durations = defaultdict(lambda: RollingWindow(window_size))
        self._request_status = defaultdict(int)
        self._db_query_durations = RollingWindow(window_size)
        self._db_slow_queries = 0
        self._vpn_prepare_create_client_ms = RollingWindow(window_size)
        self._vpn_connected_local_total = 0
        self._vpn_connected_validated_total = 0
        self._vpn_connectivity_commit_failed_total = 0
        self._vpn_connectivity_probe_public_fail_total = 0
        self._vpn_connectivity_probe_api_fail_total = 0
        self._vpn_connectivity_probe_public_fail_by_class = defaultdict(int)
        self._vpn_connectivity_probe_api_fail_by_class = defaultdict(int)
        self._lock = Lock()

    @staticmethod
    def now() -> float:
        return perf_counter()

    def record_request(self, key: str, duration_ms: float, status_code: int) -> None:
        self._request_durations[key].observe(duration_ms)
        with self._lock:
            self._request_status[f"{key} {status_code}"] += 1
        for sub in CRITICAL_ROUTE_SUBSTRINGS:
            if sub in key:
                ck = f"[critical]{sub}"
                self._request_durations[ck].observe(duration_ms)
                with self._lock:
                    self._request_status[f"{ck} {status_code}"] += 1
                break

    def record_db_query(self, duration_ms: float, is_slow: bool) -> None:
        self._db_query_durations.observe(duration_ms)
        if is_slow:
            with self._lock:
                self._db_slow_queries += 1

    def record_vpn_prepare_create_client_ms(self, duration_ms: float) -> None:
        """Длительность create_xray_client внутри POST /api/vpn/session/prepare (мс)."""
        self._vpn_prepare_create_client_ms.observe(float(duration_ms))

    def record_vpn_connectivity_event(
        self,
        *,
        event_type: str,
        message: Optional[str] = None,
        details: Optional[Dict[str, Any]] = None,
    ) -> None:
        details = details or {}

        def _normalize_failure_class(value: Any, fallback_error: Any) -> str:
            cls = str(value or "").strip().lower()
            if cls:
                return cls
            err = str(fallback_error or "").lower()
            if not err:
                return "unknown"
            if (
                "unknownhost" in err
                or "unable to resolve host" in err
                or "name or service not known" in err
            ):
                return "dns_error"
            if "ssl" in err or "tls" in err or "handshake" in err:
                return "tls_error"
            if "connection refused" in err or "connect failed" in err:
                return "tcp_refused"
            if "timed out" in err or "timeout" in err:
                return "timeout"
            if "network is unreachable" in err or "no route to host" in err:
                return "network_unreachable"
            return "other"

        with self._lock:
            if event_type == "connection_stage" and message == "connected_local":
                self._vpn_connected_local_total += 1
            elif event_type == "connection_stage" and message == "connected_validated":
                self._vpn_connected_validated_total += 1
            elif event_type == "connection_error" and message == "connectivity_commit_failed":
                self._vpn_connectivity_commit_failed_total += 1
            elif event_type == "connectivity_probe":
                if details.get("public_ok") is False:
                    self._vpn_connectivity_probe_public_fail_total += 1
                    cls = _normalize_failure_class(
                        details.get("public_failure_class"),
                        details.get("public_err"),
                    )
                    self._vpn_connectivity_probe_public_fail_by_class[cls] += 1
                if details.get("api_ok") is False:
                    self._vpn_connectivity_probe_api_fail_total += 1
                    cls = _normalize_failure_class(
                        details.get("api_failure_class"),
                        details.get("api_err"),
                    )
                    self._vpn_connectivity_probe_api_fail_by_class[cls] += 1

    def snapshot(self) -> Dict[str, Any]:
        with self._lock:
            status_counts = dict(self._request_status)
            slow_queries = self._db_slow_queries

        request_stats = {
            route: stats.snapshot().__dict__
            for route, stats in self._request_durations.items()
        }

        critical_routes = {
            route: stats.snapshot().__dict__
            for route, stats in self._request_durations.items()
            if route.startswith("[critical]")
        }
        critical_status = {
            k: v for k, v in status_counts.items() if "[critical]" in k
        }

        return {
            "generated_at": datetime.datetime.utcnow().isoformat() + "Z",
            "requests": {
                "routes": request_stats,
                "status_counts": status_counts,
                "critical_routes": critical_routes,
                "critical_status_counts": critical_status,
            },
            "timeouts_alignment": {
                "nginx_proxy_read_s": 130,
                "nginx_proxy_connect_s": 60,
                "gunicorn_worker_timeout_s": 130,
                "cloudflare_proxy_read_default_s": 100,
                "note": "Мобильный клиент session/prepare до 120s receive; nginx/gunicorn 130s. CF по умолчанию 100s — при обрывах смотреть CF.",
            },
            "database": {
                "query_duration_ms": self._db_query_durations.snapshot().__dict__,
                "slow_query_count": slow_queries,
            },
            "vpn_prepare": {
                "create_client_ms": self._vpn_prepare_create_client_ms.snapshot().__dict__,
            },
            "vpn_connectivity": {
                "connected_local_total": self._vpn_connected_local_total,
                "connected_validated_total": self._vpn_connected_validated_total,
                "connectivity_commit_failed_total": self._vpn_connectivity_commit_failed_total,
                "probe_public_fail_total": self._vpn_connectivity_probe_public_fail_total,
                "probe_api_fail_total": self._vpn_connectivity_probe_api_fail_total,
                "probe_public_fail_by_class": dict(self._vpn_connectivity_probe_public_fail_by_class),
                "probe_api_fail_by_class": dict(self._vpn_connectivity_probe_api_fail_by_class),
                "sli": {
                    "successful_validated_connect_rate": (
                        (self._vpn_connected_validated_total / self._vpn_connected_local_total)
                        if self._vpn_connected_local_total
                        else None
                    ),
                    "false_connected_rate": (
                        (self._vpn_connectivity_commit_failed_total / self._vpn_connected_local_total)
                        if self._vpn_connected_local_total
                        else None
                    ),
                    "probe_timeout_rate": (
                        (
                            self._vpn_connectivity_probe_public_fail_by_class.get("timeout", 0)
                            + self._vpn_connectivity_probe_api_fail_by_class.get("timeout", 0)
                        )
                        / max(
                            1,
                            self._vpn_connectivity_probe_public_fail_total
                            + self._vpn_connectivity_probe_api_fail_total,
                        )
                    ),
                },
            },
        }

    @staticmethod
    def _prom_label_escape(value: str) -> str:
        return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')

    def prometheus_text(self) -> str:
        """Экспорт счётчиков в text/plain для Prometheus (без внешних зависимостей)."""
        with self._lock:
            status_counts = dict(self._request_status)
            slow_queries = self._db_slow_queries
        db_stats = self._db_query_durations.snapshot()

        lines: list[str] = []
        lines.append("# HELP grani_http_requests_total HTTP requests by matched route and status code")
        lines.append("# TYPE grani_http_requests_total counter")
        for key in sorted(status_counts.keys()):
            count = status_counts[key]
            parts = key.rsplit(" ", 1)
            if len(parts) != 2 or not parts[1].isdigit():
                continue
            route_l = self._prom_label_escape(parts[0])
            status_l = self._prom_label_escape(parts[1])
            lines.append(
                f'grani_http_requests_total{{route="{route_l}",status="{status_l}"}} {int(count)}'
            )

        lines.append("# HELP grani_db_slow_queries_total Cumulative count of SQL queries over slow_query_ms threshold")
        lines.append("# TYPE grani_db_slow_queries_total counter")
        lines.append(f"grani_db_slow_queries_total {int(slow_queries)}")

        lines.append("# HELP grani_db_query_duration_ms Rolling window stats for DB query duration (ms)")
        lines.append("# TYPE grani_db_query_duration_ms summary")
        if db_stats.count:
            lines.append(f"grani_db_query_duration_ms_count {db_stats.count}")
            lines.append(f"grani_db_query_duration_ms_sum {db_stats.avg_ms * db_stats.count:.6f}")
            if db_stats.p95_ms is not None:
                lines.append(f"grani_db_query_duration_ms_p95 {db_stats.p95_ms:.6f}")
        else:
            lines.append("grani_db_query_duration_ms_count 0")
            lines.append("grani_db_query_duration_ms_sum 0")

        lines.append("# HELP grani_info Build info")
        lines.append("# TYPE grani_info gauge")
        lines.append('grani_info{version="1.0.0"} 1')

        prep = self._vpn_prepare_create_client_ms.snapshot()
        lines.append(
            "# HELP grani_vpn_session_prepare_create_client_ms "
            "Rolling window: create_client phase in session/prepare (ms)"
        )
        lines.append("# TYPE grani_vpn_session_prepare_create_client_ms summary")
        if prep.count:
            lines.append(f"grani_vpn_session_prepare_create_client_ms_count {prep.count}")
            lines.append(
                f"grani_vpn_session_prepare_create_client_ms_sum "
                f"{prep.avg_ms * prep.count:.6f}"
            )
            if prep.p95_ms is not None:
                lines.append(
                    f"grani_vpn_session_prepare_create_client_ms_p95 {prep.p95_ms:.6f}"
                )
        else:
            lines.append("grani_vpn_session_prepare_create_client_ms_count 0")
            lines.append("grani_vpn_session_prepare_create_client_ms_sum 0")

        return "\n".join(lines) + "\n"


metrics_registry = MetricsRegistry(window_size=settings.metrics_window_size)

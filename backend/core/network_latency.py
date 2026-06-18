"""
Замеры сетевой задержки до VPN-нод (ICMP и fallback TCP connect).
Используется задачами мониторинга и может вызываться из других сервисов.
"""
from __future__ import annotations

import logging
import re
import socket
import subprocess
import time
from typing import Optional, Tuple

logger = logging.getLogger(__name__)

# Типичный вывод Linux iputils-ping:
# 64 bytes from 1.2.3.4: icmp_seq=1 ttl=54 time=12.3 ms
_ICMP_TIME_RE = re.compile(r"time=([0-9]+(?:\.[0-9]+)?)\s*ms", re.IGNORECASE)


def parse_linux_ping_rtt_ms(stdout: str, stderr: str = "") -> Optional[float]:
    """Извлекает RTT (мс) из stdout/stderr `ping -c 1` (iputils)."""
    text = f"{stdout or ''}\n{stderr or ''}"
    m = _ICMP_TIME_RE.search(text)
    if not m:
        return None
    try:
        return float(m.group(1))
    except ValueError:
        return None


def measure_tcp_connect_ms(host: str, port: int, timeout_sec: float = 3.0) -> Optional[float]:
    """
    Время до установления TCP-соединения (мс), как грубая оценка задержки,
    если ICMP заблокирован.
    """
    if not host or port <= 0:
        return None
    sock: Optional[socket.socket] = None
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout_sec)
        t0 = time.perf_counter()
        sock.connect((host, port))
        ms = (time.perf_counter() - t0) * 1000.0
        return round(ms, 2)
    except OSError as e:
        logger.debug("TCP connect %s:%s failed: %s", host, port, e)
        return None
    finally:
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass


def measure_latency_to_server(
    ip_address: str,
    xray_port: Optional[int],
    default_xray_port: int = 4443,
    ping_timeout_sec: int = 5,
    tcp_timeout_sec: float = 3.0,
) -> Tuple[Optional[float], str]:
    """
    Возвращает (ping_ms или None, источник: 'icmp' | 'tcp' | 'none').

    Сначала ICMP ping, при неудаче TCP connect на порт Xray.
    """
    if not ip_address:
        return None, "none"

    try:
        proc = subprocess.run(
            ["ping", "-c", "1", "-W", str(ping_timeout_sec), ip_address],
            capture_output=True,
            text=True,
            timeout=ping_timeout_sec + 3,
        )
        if proc.returncode == 0:
            rtt = parse_linux_ping_rtt_ms(proc.stdout or "", proc.stderr or "")
            if rtt is not None:
                return round(rtt, 2), "icmp"
    except (subprocess.SubprocessError, FileNotFoundError) as e:
        logger.debug("ping subprocess failed for %s: %s", ip_address, e)

    port = int(xray_port or default_xray_port)
    tcp_ms = measure_tcp_connect_ms(ip_address, port, timeout_sec=tcp_timeout_sec)
    if tcp_ms is not None:
        return tcp_ms, "tcp"

    return None, "none"

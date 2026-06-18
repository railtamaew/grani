"""Unit tests for ICMP/TCP latency helpers."""
import pytest

from core.network_latency import parse_linux_ping_rtt_ms, measure_tcp_connect_ms


def test_parse_linux_ping_rtt_ms_standard():
    out = "PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.\n64 bytes from 8.8.8.8: icmp_seq=1 ttl=118 time=15.4 ms\n"
    assert parse_linux_ping_rtt_ms(out) == pytest.approx(15.4)


def test_parse_linux_ping_rtt_ms_no_match():
    assert parse_linux_ping_rtt_ms("no time here") is None


def test_measure_tcp_connect_ms_refused_still_returns_none_or_elapsed():
    # Порт без слушателя на localhost — быстрый отказ или RST
    r = measure_tcp_connect_ms("127.0.0.1", 1, timeout_sec=0.5)
    assert r is None or r >= 0


def test_measure_tcp_connect_ms_invalid():
    assert measure_tcp_connect_ms("", 443) is None
    assert measure_tcp_connect_ms("127.0.0.1", 0) is None

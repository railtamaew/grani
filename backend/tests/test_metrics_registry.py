from core.metrics import MetricsRegistry


def test_metrics_registry_records_request():
    registry = MetricsRegistry(window_size=5)
    registry.record_request("GET /health", 12.5, 200)
    snapshot = registry.snapshot()

    route_stats = snapshot["requests"]["routes"]["GET /health"]
    assert route_stats["count"] == 1
    assert route_stats["avg_ms"] > 0
    assert snapshot["requests"]["status_counts"]["GET /health 200"] == 1


def test_metrics_registry_critical_routes_duplicate_observation():
    registry = MetricsRegistry(window_size=5)
    registry.record_request("POST /api/auth/send-code", 30.0, 200)
    snapshot = registry.snapshot()

    crit = snapshot["requests"]["critical_routes"]["[critical]/api/auth/send-code"]
    assert crit["count"] == 1
    assert crit["avg_ms"] == 30.0
    assert (
        snapshot["requests"]["critical_status_counts"]["[critical]/api/auth/send-code 200"]
        == 1
    )
    assert "timeouts_alignment" in snapshot
    assert snapshot["timeouts_alignment"]["nginx_proxy_read_s"] == 130


def test_metrics_registry_records_db_query():
    registry = MetricsRegistry(window_size=5)
    registry.record_db_query(250.0, is_slow=True)
    snapshot = registry.snapshot()

    db_stats = snapshot["database"]["query_duration_ms"]
    assert db_stats["count"] == 1
    assert snapshot["database"]["slow_query_count"] == 1


def test_metrics_registry_prometheus_text():
    registry = MetricsRegistry(window_size=5)
    registry.record_request("GET /health", 10.0, 200)
    registry.record_db_query(5.0, is_slow=False)
    registry.record_vpn_prepare_create_client_ms(42.0)
    text = registry.prometheus_text()
    assert "grani_http_requests_total" in text
    assert 'route="GET /health"' in text
    assert "grani_db_slow_queries_total" in text
    assert "grani_info" in text
    assert "grani_vpn_session_prepare_create_client_ms" in text


def test_metrics_registry_vpn_prepare_snapshot():
    registry = MetricsRegistry(window_size=5)
    registry.record_vpn_prepare_create_client_ms(10.0)
    registry.record_vpn_prepare_create_client_ms(20.0)
    snap = registry.snapshot()
    prep = snap["vpn_prepare"]["create_client_ms"]
    assert prep["count"] == 2
    assert prep["avg_ms"] == 15.0

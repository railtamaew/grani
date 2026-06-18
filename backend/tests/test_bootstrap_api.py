"""Bootstrap API (scenario 6): response format."""
import pytest
from fastapi.testclient import TestClient
from main import app

@pytest.fixture
def client():
    return TestClient(app)

def test_bootstrap_returns_json(client):
    r = client.get("/api/vpn/bootstrap")
    assert r.status_code == 200
    data = r.json()
    assert "api_base_urls" in data
    assert "ttl_seconds" in data
    assert isinstance(data["api_base_urls"], list)
    assert isinstance(data["ttl_seconds"], int)
    assert "https://api.granilink.com/api" in data["api_base_urls"]
    assert "https://api.granilink.com:8444/api" not in data["api_base_urls"]
    assert "https://api.granilink.com/api" not in data["api_base_urls"]
    ports = data.get("xray_expected_ports") or {}
    assert ports.get("xray_vless") == 4443
    assert ports.get("xray_vmess") == 8443
    assert ports.get("xray_reality") == 2053

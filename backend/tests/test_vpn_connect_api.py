"""
API-тесты сценариев: connect без device_id, GET config по client_id, disconnect по client_id,
create-client по device_id, disconnect по device_id (как в приложении).

Требуется httpx<0.28 из-за несовместимости Starlette TestClient с httpx>=0.28.
Для запуска тестов: pip install 'httpx>=0.25,<0.28' (или использовать venv с этим ограничением).
"""
import pytest
from unittest.mock import MagicMock
from fastapi.testclient import TestClient

from main import app
from core.database import get_db
from core.dependencies import get_vpn_operations_service
from application.services.vpn_operations_service import VPNOperationsService
from domain.models.server import Server
from models import UserVpnConnection
from models.user import Device
from services.auth_service import AuthService
from services.device_manager import DeviceManager
from services.wireguard_manager import WireGuardManager


@pytest.fixture
def test_server(db_session):
    server = Server(
        name="Test API Server",
        ip_address="10.0.0.1",
        country="RU",
        is_active=True,
        wireguard_port=51820,
        supported_protocols=["wireguard", "xray_vless", "xray_vmess", "xray_reality"],
    )
    db_session.add(server)
    db_session.commit()
    db_session.refresh(server)
    return server


@pytest.fixture
def device_manager_for_api(db_session):
    return DeviceManager(db_session, WireGuardManager())


@pytest.fixture
def test_device_for_api(db_session, test_user, device_manager_for_api):
    """Устройство для тестов create-client и disconnect по device_id."""
    device = device_manager_for_api.register_device(test_user, {
        "name": "Test Device API",
        "device_id": "test-device-api-001",
        "platform": "android",
    })
    db_session.refresh(device)
    return device


@pytest.fixture
def vpn_service_for_api(db_session, device_manager_for_api):
    svc = VPNOperationsService(db_session, device_manager_for_api)
    svc.xray_manager.create_vless_client = MagicMock(return_value={
        "success": True,
        "config": "vless://test-config",
        "client_id": "test-client-uuid",
        "ip_address": "10.0.0.2",
        "apply_state": {"config_sha256": "abc123", "config_revision": "rev-abc123"},
    })
    svc.xray_manager._generate_client_json_config = MagicMock(
        return_value={"add": "1.2.3.4", "id": "test-client-uuid", "port": "443"}
    )
    svc.xray_manager._generate_client_config = MagicMock(return_value="vless://generated")
    svc.get_xray_apply_state = MagicMock(
        return_value={
            "server_id": 1,
            "requested_config_revision": "abc123",
            "matched": True,
            "status": "applied",
            "is_applied": True,
            "apply_state": {
                "status": "applied",
                "ack_mode": "celery_task",
                "config_revision": "abc123",
                "celery_task_id": "task-1",
            },
        }
    )
    svc.xray_manager.commit_staged_config = MagicMock(
        return_value={"status": "queued", "apply_branch": "commit_staged"}
    )
    return svc


@pytest.fixture
def api_client(db_session, test_user, test_server, vpn_service_for_api):
    test_user.trial_active = True
    db_session.commit()

    def override_get_db():
        yield db_session

    def override_vpn():
        return vpn_service_for_api

    app.dependency_overrides[get_db] = override_get_db
    app.dependency_overrides[get_vpn_operations_service] = override_vpn
    with TestClient(app) as c:
        yield c
    app.dependency_overrides.pop(get_db, None)
    app.dependency_overrides.pop(get_vpn_operations_service, None)


def test_connect_without_device_id_returns_200_and_client_id(api_client, test_user, test_server, monkeypatch):
    """POST /vpn/connect без device_id возвращает 200, client_id и config."""
    from core import config as core_config
    monkeypatch.setattr(core_config.settings, "test_user_emails", [test_user.email])
    token = AuthService.create_access_token(test_user.id)
    response = api_client.post(
        "/api/vpn/connect",
        json={"server_id": test_server.id, "protocol": "xray_vless"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    data = response.json()
    assert data.get("success") is True
    assert "client_id" in data
    assert data.get("client_id") == "test-client-uuid"
    assert "config" in data


def test_session_prepare_xray_same_body_as_connect(api_client, test_user, test_server, monkeypatch):
    """POST /api/vpn/session/prepare в read-only режиме не создает клиента."""
    from core import config as core_config
    monkeypatch.setattr(core_config.settings, "test_user_emails", [test_user.email])
    token = AuthService.create_access_token(test_user.id)
    response = api_client.post(
        "/api/vpn/session/prepare",
        json={"server_id": test_server.id, "protocol": "xray_vless"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 409


def test_get_config_for_connection_client_id(api_client, test_user, test_server, db_session, vpn_service_for_api):
    """GET /api/vpn/xray/config/{client_id} для client_id из user_vpn_connections возвращает 200 и config."""
    conn = UserVpnConnection(
        user_id=test_user.id,
        server_id=test_server.id,
        protocol="xray_vless",
        vpn_client_id="conn-client-id-123",
        vpn_protocol="vless",
    )
    db_session.add(conn)
    db_session.commit()

    token = AuthService.create_access_token(test_user.id)
    response = api_client.get(
        "/api/vpn/xray/config/conn-client-id-123",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    data = response.json()
    assert "config" in data
    assert data.get("client_id") == "conn-client-id-123"


def test_disconnect_by_client_id_returns_200(api_client, test_user, test_server, db_session):
    """POST /vpn/disconnect с телом {client_id} возвращает 200."""
    conn = UserVpnConnection(
        user_id=test_user.id,
        server_id=test_server.id,
        protocol="xray_vless",
        vpn_client_id="disconnect-test-id",
        connection_id="conn-uuid-disconnect",
    )
    db_session.add(conn)
    db_session.commit()

    token = AuthService.create_access_token(test_user.id)
    response = api_client.post(
        "/api/vpn/disconnect",
        json={"client_id": "disconnect-test-id"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    data = response.json()
    assert "message" in data


def test_xray_create_client_returns_200_json_config_client_id(
    api_client, test_user, test_server, test_device_for_api, monkeypatch
):
    """POST /api/vpn/xray/create-client с server_id, protocol, device_id возвращает 200, json_config, client_id."""
    from core import config as core_config
    monkeypatch.setattr(core_config.settings, "test_user_emails", [test_user.email])
    token = AuthService.create_access_token(test_user.id)
    response = api_client.post(
        "/api/vpn/xray/create-client",
        json={
            "server_id": test_server.id,
            "protocol": "xray_vless",
            "device_id": "test-device-api-001",
        },
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    data = response.json()
    assert data.get("success") is True
    assert "client_id" in data
    assert data.get("client_id") == "test-client-uuid"
    assert "json_config" in data
    assert data["json_config"] == {"add": "1.2.3.4", "id": "test-client-uuid", "port": "443"}
    assert data.get("payload_fingerprint")
    assert data.get("active_config_hash") == "abc123"


def test_disconnect_by_device_id_returns_200_and_clears_is_active(
    api_client, test_user, test_server, test_device_for_api, db_session
):
    """POST /api/vpn/disconnect с телом device_id (как в приложении) возвращает 200 и сбрасывает is_active."""
    test_device_for_api.is_active = True
    test_device_for_api.current_server_id = test_server.id
    db_session.commit()
    db_session.refresh(test_device_for_api)

    token = AuthService.create_access_token(test_user.id)
    response = api_client.post(
        "/api/vpn/disconnect",
        json={"device_id": "test-device-api-001"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    data = response.json()
    assert "message" in data

    db_session.refresh(test_device_for_api)
    assert test_device_for_api.is_active is False


def test_xray_apply_state_endpoint_returns_state(api_client, test_user, test_server, monkeypatch):
    """GET /api/vpn/xray/apply-state возвращает apply-state по revision."""
    from core import config as core_config

    monkeypatch.setattr(core_config.settings, "test_user_emails", [test_user.email])
    token = AuthService.create_access_token(test_user.id)
    response = api_client.get(
        "/api/vpn/xray/apply-state",
        params={"server_id": test_server.id, "config_revision": "abc123"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    data = response.json()
    assert data["matched"] is True
    assert data["status"] == "applied"
    assert data["is_applied"] is True
    assert data["apply_state"]["ack_mode"] == "celery_task"
    assert data["retry_after_sec"] == 0


def test_xray_apply_state_long_poll_applied_before_timeout(
    api_client, test_user, test_server, vpn_service_for_api, monkeypatch
):
    from core import config as core_config
    from api import xray as xray_api

    monkeypatch.setattr(core_config.settings, "test_user_emails", [test_user.email])

    async def _fast_sleep(_: float):
        return None

    monkeypatch.setattr(xray_api.asyncio, "sleep", _fast_sleep)
    vpn_service_for_api.get_xray_apply_state.side_effect = [
        {
            "server_id": test_server.id,
            "requested_config_revision": "abc123",
            "matched": True,
            "status": "queued",
            "is_applied": False,
            "apply_state": {"status": "queued"},
        },
        {
            "server_id": test_server.id,
            "requested_config_revision": "abc123",
            "matched": True,
            "status": "applied",
            "is_applied": True,
            "apply_state": {"status": "applied"},
        },
    ]

    token = AuthService.create_access_token(test_user.id)
    response = api_client.get(
        "/api/vpn/xray/apply-state",
        params={
            "server_id": test_server.id,
            "config_revision": "abc123",
            "wait_for": "applied",
            "timeout_sec": 2,
        },
        headers={"Authorization": f"Bearer {token}"},
    )

    assert response.status_code == 200
    data = response.json()
    assert data["is_applied"] is True
    assert data["status"] == "applied"
    assert data["timed_out"] is False
    assert data["retry_after_sec"] == 0
    assert vpn_service_for_api.get_xray_apply_state.call_count >= 2


def test_xray_apply_state_long_poll_timeout(
    api_client, test_user, test_server, vpn_service_for_api, monkeypatch
):
    from core import config as core_config
    from api import xray as xray_api

    monkeypatch.setattr(core_config.settings, "test_user_emails", [test_user.email])

    async def _fast_sleep(_: float):
        return None

    monkeypatch.setattr(xray_api.asyncio, "sleep", _fast_sleep)
    queued_state = {
        "server_id": test_server.id,
        "requested_config_revision": "abc123",
        "matched": True,
        "status": "queued",
        "is_applied": False,
        "apply_state": {"status": "queued"},
    }
    vpn_service_for_api.get_xray_apply_state.side_effect = [queued_state] * 8

    token = AuthService.create_access_token(test_user.id)
    response = api_client.get(
        "/api/vpn/xray/apply-state",
        params={
            "server_id": test_server.id,
            "config_revision": "abc123",
            "wait_for": "applied",
            "timeout_sec": 1,
        },
        headers={"Authorization": f"Bearer {token}"},
    )

    assert response.status_code == 200
    data = response.json()
    assert data["is_applied"] is False
    assert data["status"] == "queued"
    assert data["timed_out"] is True
    assert data["retry_after_sec"] == 2


def test_xray_commit_staged_endpoint_returns_result(
    api_client, test_user, test_server, monkeypatch
):
    from core import config as core_config

    monkeypatch.setattr(core_config.settings, "test_user_emails", [test_user.email])
    token = AuthService.create_access_token(test_user.id)
    response = api_client.post(
        "/api/vpn/xray/commit-staged",
        json={"server_id": test_server.id},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    data = response.json()
    assert data["server_id"] == test_server.id
    assert data["result"]["apply_branch"] == "commit_staged"

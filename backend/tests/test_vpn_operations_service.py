import pytest
from fastapi import HTTPException
from unittest.mock import MagicMock

from models.server import Server
from services.device_manager import DeviceManager
from services.vpn_operations_service import VPNOperationsService
from services.wireguard_manager import WireGuardManager


@pytest.fixture
def vpn_service(db_session):
    wg_manager = WireGuardManager()
    device_manager = DeviceManager(db_session, wg_manager)
    return VPNOperationsService(db_session, device_manager)


@pytest.fixture
def test_server(db_session):
    server = Server(
        name="Test Server",
        ip_address="192.168.1.10",
        country="US",
        city="New York",
        is_active=True,
        wireguard_port=51820,
        supported_protocols=["wireguard", "xray_vless", "xray_vmess", "xray_reality"],
    )
    db_session.add(server)
    db_session.commit()
    db_session.refresh(server)
    return server


@pytest.fixture
def test_device(db_session, test_user):
    device_manager = DeviceManager(db_session, WireGuardManager())
    device = device_manager.register_device(test_user, {
        'name': 'Test Device',
        'device_id': 'test-device-vpn-ops',
        'platform': 'android'
    })
    db_session.refresh(device)
    return device


def test_create_xray_client_failure_raises(vpn_service, test_user, test_device, test_server):
    vpn_service.xray_manager.create_vless_client = MagicMock(return_value={
        "success": False,
        "config": "",
        "error": "xray error",
        "client_id": "vless_test",
    })

    with pytest.raises(HTTPException) as exc_info:
        vpn_service.create_xray_client(test_user, test_device, test_server, "vless")

    assert exc_info.value.status_code == 500
    assert "Ошибка создания Xray клиента" in exc_info.value.detail


def test_create_xray_client_already_connected_returns_400(vpn_service, test_user, test_device, test_server):
    """create_xray_client возвращает 400 при device.is_active=True (клиент сделает force disconnect + retry)."""
    test_device.is_active = True
    vpn_service.db.commit()
    vpn_service.db.refresh(test_device)

    with pytest.raises(HTTPException) as exc_info:
        vpn_service.create_xray_client(test_user, test_device, test_server, "vless")

    assert exc_info.value.status_code == 400
    assert "уже подключено" in exc_info.value.detail


def test_create_xray_client_empty_config_raises(vpn_service, test_user, test_device, test_server):
    vpn_service.xray_manager.create_vless_client = MagicMock(return_value={
        "success": True,
        "config": "",
        "client_id": "vless_test",
    })
    vpn_service.xray_manager._generate_client_json_config = MagicMock(return_value=None)

    with pytest.raises(HTTPException) as exc_info:
        vpn_service.create_xray_client(test_user, test_device, test_server, "vless")

    assert exc_info.value.status_code == 500
    assert "конфигурацию" in exc_info.value.detail


def test_create_xray_client_invalid_json_config_raises(vpn_service, test_user, test_device, test_server):
    vpn_service.xray_manager.create_vless_client = MagicMock(return_value={
        "success": True,
        "config": "vless://example",
        "client_id": "vless_test",
    })
    vpn_service.xray_manager._generate_client_json_config = MagicMock(return_value={
        "add": "",
        "port": "abc",
        "id": ""
    })

    with pytest.raises(HTTPException) as exc_info:
        vpn_service.create_xray_client(test_user, test_device, test_server, "vless")

    assert exc_info.value.status_code == 500


def test_disconnect_device_returns_success_when_state_cleared(
    vpn_service,
    test_user,
    test_device,
    db_session
):
    test_device.is_active = True
    db_session.commit()

    result = vpn_service.disconnect_device(test_user, test_device, force=False)

    assert result["message"] == "Отключение выполнено"
    assert result["force"] is False
    db_session.refresh(test_device)
    assert test_device.is_active is False


def test_disconnect_device_does_not_remove_client_on_node(vpn_service, test_user, test_device, db_session):
    """disconnect_device только сбрасывает состояние в БД; Xray-клиент на ноде не удаляется (реконнект из кэша)."""
    test_device.is_active = True
    test_device.vpn_client_id = "vless-test-123"
    db_session.commit()

    vpn_service.xray_manager.remove_client = MagicMock()
    result = vpn_service.disconnect_device(test_user, test_device, force=False)

    assert result["message"] == "Отключение выполнено"
    vpn_service.xray_manager.remove_client.assert_not_called()


def test_create_xray_client_invalid_json_config_raises(vpn_service, test_user, test_device, test_server):
    vpn_service.xray_manager.create_vless_client = MagicMock(return_value={
        "success": True,
        "config": "vless://example",
        "client_id": "vless_test",
    })
    vpn_service.xray_manager._generate_client_json_config = MagicMock(return_value={
        "add": "",
        "port": "abc",
        "id": ""
    })

    with pytest.raises(HTTPException) as exc_info:
        vpn_service.create_xray_client(test_user, test_device, test_server, "vless")

    assert exc_info.value.status_code == 500


def test_create_xray_client_invalid_json_config_raises(vpn_service, test_user, test_device, test_server):
    vpn_service.xray_manager.create_vless_client = MagicMock(return_value={
        "success": True,
        "config": "vless://example",
        "client_id": "vless_test",
    })
    vpn_service.xray_manager._generate_client_json_config = MagicMock(return_value={
        "add": "",
        "port": "abc",
        "id": ""
    })

    with pytest.raises(HTTPException) as exc_info:
        vpn_service.create_xray_client(test_user, test_device, test_server, "vless")

    assert exc_info.value.status_code == 500

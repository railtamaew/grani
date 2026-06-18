from unittest.mock import Mock

import pytest

from application.services.vpn_manager_facade import VPNManagerFacade


@pytest.fixture
def mock_vpn_service():
    svc = Mock()
    svc.validate_and_get_server.return_value = Mock(id=77)
    svc.validate_and_get_device.return_value = Mock(id=11, device_id="dev-1")
    svc.connect_device.return_value = {"success": True, "client_id": "xray_1"}
    svc.get_or_create_connection.return_value = {"success": True, "connection_id": "conn_1"}
    svc.disconnect_device.return_value = {"success": True}
    svc.disconnect_by_client_id.return_value = {"success": True}
    return svc


def test_connect_facade_uses_connection_mode_without_device_id(test_user, mock_vpn_service):
    facade = VPNManagerFacade(mock_vpn_service)

    result = facade.connect_vpn(
        user=test_user,
        device_id="",
        server_id=77,
        protocol="xray_vless",
    )

    assert result["success"] is True
    mock_vpn_service.get_or_create_connection.assert_called_once_with(
        test_user,
        mock_vpn_service.validate_and_get_server.return_value,
        "xray_vless",
    )
    mock_vpn_service.connect_device.assert_not_called()


def test_connect_facade_uses_device_mode_with_autoregister(test_user, mock_vpn_service):
    facade = VPNManagerFacade(mock_vpn_service)

    result = facade.connect_vpn(
        user=test_user,
        device_id="dev-1",
        server_id=77,
        protocol="xray_reality",
        device_data={"platform": "android"},
    )

    assert result["success"] is True
    mock_vpn_service.validate_and_get_device.assert_called_once()
    _, kwargs = mock_vpn_service.validate_and_get_device.call_args
    assert kwargs["auto_register"] is True
    assert kwargs["device_data"]["device_id"] == "dev-1"
    assert kwargs["device_data"]["platform"] == "android"
    mock_vpn_service.connect_device.assert_called_once()


def test_disconnect_facade_by_client_id(test_user, mock_vpn_service):
    facade = VPNManagerFacade(mock_vpn_service)

    result = facade.disconnect_vpn(
        user=test_user,
        device_id="",
        client_id="xray-client-1",
        force=True,
    )

    assert result["success"] is True
    mock_vpn_service.disconnect_by_client_id.assert_called_once_with(
        test_user,
        "xray-client-1",
        force=True,
    )

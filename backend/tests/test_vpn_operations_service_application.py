import uuid
from datetime import datetime

import pytest
from fastapi import HTTPException
from unittest.mock import MagicMock

from application.services.device_manager import DeviceManager
from application.services.vpn_operations_service import (
    VPNOperationsService,
    ConnectionConfigView,
)
from domain.models.server import ConnectionLog, Server
from domain.models.user import Device
from models import UserVpnConnection
from domain.models.edge_node_assignment import EdgeNodeAssignment


@pytest.fixture
def vpn_service_application(db_session):
    return VPNOperationsService(db_session, MagicMock())


@pytest.fixture
def vpn_service_with_devices(db_session):
    return VPNOperationsService(db_session, DeviceManager(db_session, None))


@pytest.fixture
def test_server(db_session):
    server = Server(
        name="Test Server",
        ip_address="192.168.1.11",
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
    device = Device(
        user_id=test_user.id,
        device_id="test-device-vpn-ops-app",
        device_name="Test Device",
        wireguard_public_key="device_public_key",
        wireguard_private_key="device_private_key",
        is_active=False,
    )
    db_session.add(device)
    db_session.commit()
    db_session.refresh(device)
    return device


def test_validate_inactive_device_auto_register_reuses_row_no_duplicate(
    vpn_service_with_devices, test_user, db_session
):
    """Тот же строковый device_id; неактивная строка — обновляем без второй записи."""
    did = str(uuid.uuid4())
    old = Device(
        user_id=test_user.id,
        device_id=did,
        device_name="Old",
        is_active=False,
    )
    db_session.add(old)
    db_session.commit()
    db_session.refresh(old)

    dev = vpn_service_with_devices.validate_and_get_device(
        test_user,
        did,
        auto_register=True,
        device_data={"name": "Reconnect", "device_id": did, "platform": "android"},
    )
    assert dev.id == old.id
    assert dev.device_id == did
    assert dev.is_active is False
    assert dev.device_name == "Reconnect"
    assert db_session.query(Device).filter(Device.device_id == did).count() == 1


def test_validate_inactive_device_prepare_purges_extra_inactive_dupes(
    vpn_service_with_devices, test_user, db_session
):
    """Две неактивные строки с одним device_id — после prepare остаётся одна (каноническая)."""
    did = str(uuid.uuid4())
    first = Device(
        user_id=test_user.id,
        device_id=did,
        device_name="First",
        is_active=False,
    )
    second = Device(
        user_id=test_user.id,
        device_id=did,
        device_name="Second",
        is_active=False,
    )
    db_session.add_all([first, second])
    db_session.commit()
    db_session.refresh(first)
    db_session.refresh(second)
    keeper_id = max(first.id, second.id)

    dev = vpn_service_with_devices.validate_and_get_device(
        test_user,
        did,
        auto_register=True,
        device_data={"name": "Merged", "device_id": did, "platform": "android"},
    )
    assert db_session.query(Device).filter(Device.device_id == did).count() == 1
    assert dev.id == keeper_id
    assert dev.device_name == "Merged"


def test_create_xray_client_invalid_json_config_raises(vpn_service_application, test_user, test_device, test_server):
    vpn_service_application.xray_manager.create_vless_client = MagicMock(return_value={
        "success": True,
        "config": "vless://example",
        "client_id": "vless_test",
    })
    vpn_service_application.xray_manager._generate_client_json_config = MagicMock(return_value={
        "add": "",
        "port": "abc",
        "id": ""
    })

    with pytest.raises(HTTPException) as exc_info:
        vpn_service_application.create_xray_client(test_user, test_device, test_server, "vless")

    assert exc_info.value.status_code == 500


def test_create_xray_client_empty_config_raises(vpn_service_application, test_user, test_device, test_server):
    vpn_service_application.xray_manager.create_vless_client = MagicMock(return_value={
        "success": True,
        "config": "",
        "client_id": "vless_test",
    })
    vpn_service_application.xray_manager._generate_client_json_config = MagicMock(return_value=None)

    with pytest.raises(HTTPException) as exc_info:
        vpn_service_application.create_xray_client(test_user, test_device, test_server, "vless")

    assert exc_info.value.status_code == 500


def test_disconnect_device_returns_success_when_state_cleared(
    vpn_service_application,
    test_user,
    test_device,
    db_session
):
    test_device.is_active = True
    db_session.commit()

    result = vpn_service_application.disconnect_device(test_user, test_device, force=False)

    assert result["message"] == "Отключение выполнено"
    assert result["force"] is False
    db_session.refresh(test_device)
    assert test_device.is_active is False


def test_get_device_by_client_id_returns_connection_view_when_in_user_vpn_connections(
    vpn_service_application, test_user, test_server
):
    """get_device_by_client_id возвращает ConnectionConfigView, если client_id найден в user_vpn_connections."""
    conn = UserVpnConnection(
        user_id=test_user.id,
        server_id=test_server.id,
        protocol="xray_vless",
        vpn_client_id="conn-uuid-xray-123",
        vpn_protocol="vless",
    )
    vpn_service_application.db.add(conn)
    vpn_service_application.db.commit()

    result = vpn_service_application.get_device_by_client_id(test_user, "conn-uuid-xray-123")

    assert isinstance(result, ConnectionConfigView)
    assert result.vpn_client_id == "conn-uuid-xray-123"
    assert result.current_server_id == test_server.id
    assert result.vpn_protocol == "vless"


def test_get_device_by_client_id_raises_404_when_not_found(vpn_service_application, test_user):
    """get_device_by_client_id возвращает 404, если ни устройство, ни соединение не найдены."""
    with pytest.raises(HTTPException) as exc_info:
        vpn_service_application.get_device_by_client_id(test_user, "nonexistent-client-id")
    assert exc_info.value.status_code == 404
    assert "не найден" in exc_info.value.detail.lower() or "Клиент не найден" in exc_info.value.detail


def test_get_or_create_connection_xray_returns_existing_config_without_creating(
    vpn_service_application, test_user, test_server
):
    """get_or_create_connection для XRay при существующем vpn_client_id возвращает конфиг без вызова create."""
    test_user.trial_active = True
    conn = UserVpnConnection(
        user_id=test_user.id,
        server_id=test_server.id,
        protocol="xray_vless",
        vpn_client_id="existing-xray-uuid",
        vpn_protocol="vless",
    )
    vpn_service_application.db.add(conn)
    vpn_service_application.db.commit()

    vpn_service_application.xray_manager._generate_client_config = MagicMock(return_value="vless://...")
    create_vless_mock = MagicMock()
    vpn_service_application.xray_manager.create_vless_client = create_vless_mock

    result = vpn_service_application.get_or_create_connection(test_user, test_server, "xray_vless")

    assert result["success"] is True
    assert result["client_id"] == "existing-xray-uuid"
    assert isinstance(result.get("config"), str) and result["config"].startswith("vless://")
    create_vless_mock.assert_not_called()


def test_get_or_create_connection_xray_creates_client_when_no_connection(
    vpn_service_application, test_user, test_server
):
    """get_or_create_connection для XRay при отсутствии записи создаёт клиента и сохраняет в user_vpn_connections."""
    test_user.trial_active = True
    vpn_service_application.xray_manager.create_vless_client = MagicMock(return_value={
        "success": True,
        "config": "vless://new",
        "client_id": "new-uuid",
        "ip_address": "10.0.0.2",
    })
    vpn_service_application.xray_manager._generate_client_json_config = MagicMock(
        return_value={"add": "1.2.3.4", "id": "new-uuid", "port": "443"}
    )

    result = vpn_service_application.get_or_create_connection(test_user, test_server, "xray_vless")

    assert result["success"] is True
    assert result["client_id"] == "new-uuid"
    vpn_service_application.xray_manager.create_vless_client.assert_called_once()
    conn = vpn_service_application.connection_repo.get_by_user_server_protocol(
        test_user.id, test_server.id, "xray_vless"
    )
    assert conn is not None
    assert conn.vpn_client_id == "new-uuid"


def test_get_xray_apply_state_returns_unknown_when_revision_mismatch(
    vpn_service_application, test_user, test_server
):
    vpn_service_application.xray_manager.get_last_apply_state = MagicMock(
        return_value={
            "status": "queued",
            "ack_mode": "celery_task",
            "config_revision": "rev-1",
        }
    )

    result = vpn_service_application.get_xray_apply_state(
        test_user,
        test_server.id,
        "rev-2",
    )

    assert result["matched"] is False
    assert result["status"] == "unknown"
    assert result["is_applied"] is False


def test_get_xray_apply_state_edge_completed_sets_applied(
    vpn_service_application, test_user, test_server
):
    edge = EdgeNodeAssignment(
        server_id=test_server.id,
        assignment_type="apply_xray_config",
        payload_json='{"config_b64":"x","expected_hash":"sha256:abc"}',
        status="completed",
        result_status="ok",
        applied_config_hash="sha256:abc",
    )
    vpn_service_application.db.add(edge)
    vpn_service_application.db.commit()
    vpn_service_application.db.refresh(edge)

    vpn_service_application.xray_manager.get_last_apply_state = MagicMock(
        return_value={
            "status": "queued",
            "ack_mode": "edge_assignment",
            "edge_assignment_id": edge.id,
            "config_revision": "abc123",
        }
    )

    result = vpn_service_application.get_xray_apply_state(
        test_user,
        test_server.id,
        "abc123",
    )

    assert result["matched"] is True
    assert result["status"] == "applied"
    assert result["is_applied"] is True
    assert result["edge_assignment"]["id"] == edge.id


def test_get_xray_apply_state_reason_deferred_active_sessions(
    vpn_service_application, test_user, test_server, db_session
):
    edge = EdgeNodeAssignment(
        server_id=test_server.id,
        assignment_type="apply_xray_config",
        payload_json='{"config_b64":"x","expected_hash":"sha256:abc"}',
        status="pending",
    )
    vpn_service_application.db.add(edge)
    vpn_service_application.db.commit()
    vpn_service_application.db.refresh(edge)

    dev = Device(
        user_id=test_user.id,
        device_id="reason-defer-dev",
        is_active=True,
    )
    db_session.add(dev)
    db_session.commit()
    db_session.refresh(dev)
    log = ConnectionLog(
        user_id=test_user.id,
        device_id=dev.id,
        server_id=test_server.id,
        connection_type="connect",
        connected_at=datetime.utcnow(),
        disconnected_at=None,
    )
    db_session.add(log)
    db_session.commit()

    vpn_service_application.xray_manager.get_last_apply_state = MagicMock(
        return_value={
            "status": "queued",
            "ack_mode": "edge_assignment",
            "edge_assignment_id": edge.id,
            "config_revision": "abc123",
        }
    )

    result = vpn_service_application.get_xray_apply_state(
        test_user,
        test_server.id,
        "abc123",
    )

    assert result["matched"] is True
    assert result["status"] == "queued"
    assert result.get("reason_code") == "deferred_active_sessions"
    assert result.get("active_xray_sessions") == 1


def test_get_xray_apply_state_reason_node_applying(
    vpn_service_application, test_user, test_server
):
    edge = EdgeNodeAssignment(
        server_id=test_server.id,
        assignment_type="apply_xray_config",
        payload_json='{"config_b64":"x","expected_hash":"sha256:abc"}',
        status="dispatched",
    )
    vpn_service_application.db.add(edge)
    vpn_service_application.db.commit()
    vpn_service_application.db.refresh(edge)

    vpn_service_application.xray_manager.get_last_apply_state = MagicMock(
        return_value={
            "status": "queued",
            "ack_mode": "edge_assignment",
            "edge_assignment_id": edge.id,
            "config_revision": "abc123",
        }
    )

    result = vpn_service_application.get_xray_apply_state(
        test_user,
        test_server.id,
        "abc123",
    )

    assert result["matched"] is True
    assert result["status"] == "queued"
    assert result.get("reason_code") == "node_applying_config"
    assert result.get("active_xray_sessions") == 0

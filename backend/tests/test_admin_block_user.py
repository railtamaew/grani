"""
Тесты блокировки пользователя: проверка отключения устройств от VPN.
"""
import pytest
from unittest.mock import MagicMock
from fastapi.testclient import TestClient

from models.user import User, Device, UserRole
from services.auth_service import AuthService
from core.database import get_db
from core.dependencies import get_vpn_operations_service


@pytest.fixture
def admin_user(db_session):
    """Админ для вызова block."""
    user = User(
        email="admin@block.test",
        password_hash=AuthService.hash_password("admin123"),
        is_active=True,
        role=UserRole.OWNER,
        auth_provider="email",
    )
    db_session.add(user)
    db_session.commit()
    db_session.refresh(user)
    return user


@pytest.fixture
def target_user_with_devices(db_session):
    """Пользователь с двумя активными устройствами."""
    user = User(
        email="target@block.test",
        password_hash=None,
        is_active=True,
        auth_provider="email",
    )
    db_session.add(user)
    db_session.commit()
    db_session.refresh(user)
    for i in range(2):
        dev = Device(
            user_id=user.id,
            device_id=f"device-{user.id}-{i}",
            is_active=True,
        )
        db_session.add(dev)
    db_session.commit()
    return user


@pytest.fixture
def mock_vpn_service():
    """Мок VPNOperationsService: записывает вызовы disconnect_device."""
    mock = MagicMock()
    mock.disconnect_device = MagicMock(return_value={"message": "ok"})
    return mock


@pytest.fixture
def client(db_session, admin_user, target_user_with_devices, mock_vpn_service):
    """TestClient с подменой get_db и get_vpn_operations_service."""
    from main import app

    def override_get_db():
        yield db_session

    def override_vpn():
        return mock_vpn_service

    app.dependency_overrides[get_db] = override_get_db
    app.dependency_overrides[get_vpn_operations_service] = override_vpn
    with TestClient(app) as c:
        yield c
    app.dependency_overrides.pop(get_db, None)
    app.dependency_overrides.pop(get_vpn_operations_service, None)


def test_block_user_disconnects_devices(client, admin_user, target_user_with_devices, mock_vpn_service, db_session):
    """При блокировке пользователя вызывается disconnect_device для каждого активного устройства."""
    token = AuthService.create_access_token(admin_user.id)
    target_id = target_user_with_devices.id
    response = client.put(
        f"/api/admin/users/{target_id}/block",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    assert mock_vpn_service.disconnect_device.call_count == 2
    db_session.refresh(target_user_with_devices)
    assert target_user_with_devices.is_active is False

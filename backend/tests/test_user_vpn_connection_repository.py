"""
Тесты для UserVpnConnectionRepository.
"""
import pytest
from uuid import uuid4

from models import UserVpnConnection
from models.server import Server
from infrastructure.repositories.user_vpn_connection_repository import UserVpnConnectionRepository


@pytest.fixture
def test_server(db_session):
    """Тестовый сервер."""
    s = Server(
        name="Test Server",
        ip_address="192.168.1.1",
        country="RU",
        is_active=True,
    )
    db_session.add(s)
    db_session.commit()
    db_session.refresh(s)
    return s


@pytest.fixture
def connection_repo(db_session):
    """Репозиторий user_vpn_connections."""
    return UserVpnConnectionRepository(db_session)


class TestUserVpnConnectionRepository:
    """Тесты get_by_user_server_protocol и get_by_client_or_connection_id."""

    def test_get_by_user_server_protocol_not_found(
        self, connection_repo, test_user, test_server
    ):
        """Нет записи — возвращается None."""
        assert connection_repo.get_by_user_server_protocol(
            test_user.id, test_server.id, "xray_vless"
        ) is None

    def test_get_by_user_server_protocol_found(
        self, connection_repo, test_user, test_server
    ):
        """Есть запись — возвращается она."""
        conn = connection_repo.create(
            user_id=test_user.id,
            server_id=test_server.id,
            protocol="xray_vless",
            vpn_client_id="uuid-from-xray",
            vpn_protocol="vless",
        )
        found = connection_repo.get_by_user_server_protocol(
            test_user.id, test_server.id, "xray_vless"
        )
        assert found is not None
        assert found.id == conn.id
        assert found.vpn_client_id == "uuid-from-xray"

    def test_get_by_client_or_connection_id_by_vpn_client_id(
        self, connection_repo, test_user, test_server
    ):
        """Поиск по vpn_client_id (XRay)."""
        connection_repo.create(
            user_id=test_user.id,
            server_id=test_server.id,
            protocol="xray_vless",
            vpn_client_id="xray-uuid-123",
            vpn_protocol="vless",
        )
        found = connection_repo.get_by_client_or_connection_id("xray-uuid-123", test_user.id)
        assert found is not None
        assert found.vpn_client_id == "xray-uuid-123"

    def test_get_by_client_or_connection_id_by_connection_id(
        self, connection_repo, test_user, test_server
    ):
        """Поиск по connection_id (WireGuard)."""
        cid = str(uuid4())
        connection_repo.create(
            user_id=test_user.id,
            server_id=test_server.id,
            protocol="wireguard",
            connection_id=cid,
            wireguard_public_key="pub",
            wireguard_private_key="priv",
            ip_address="10.0.0.2",
        )
        found = connection_repo.get_by_client_or_connection_id(cid, test_user.id)
        assert found is not None
        assert found.connection_id == cid

    def test_get_by_client_or_connection_id_not_found(
        self, connection_repo, test_user
    ):
        """Нет записи с таким client_id — None."""
        assert connection_repo.get_by_client_or_connection_id("no-such-id", test_user.id) is None

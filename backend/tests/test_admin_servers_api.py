"""
Тесты GET /api/admin/servers: пагинация и формат ответа ServersListResponse.
"""
import pytest
from fastapi.testclient import TestClient

from core.database import get_db
from models.user import User, UserRole
from models.server import Server
from services.auth_service import AuthService


@pytest.fixture
def admin_user(db_session):
    """Админ для тестов списка серверов."""
    user = User(
        email="admin-servers@test.local",
        password_hash=AuthService.hash_password("AdminPass123"),
        is_active=True,
        is_verified=True,
        role=UserRole.OWNER,
        auth_provider="email",
    )
    db_session.add(user)
    db_session.commit()
    db_session.refresh(user)
    return user


@pytest.fixture
def admin_token(admin_user):
    return AuthService.create_access_token(admin_user.id)


@pytest.fixture
def sample_server(db_session):
    """Один сервер для проверки списка."""
    s = Server(
        name="Test Server",
        country="RU",
        city="Moscow",
        ip_address="10.0.0.1",
        wireguard_port=51820,
        max_users=100,
        current_users=0,
        is_active=True,
        is_local=True,
    )
    db_session.add(s)
    db_session.commit()
    db_session.refresh(s)
    return s


@pytest.fixture
def client(db_session):
    """TestClient с подменой get_db."""
    from main import app

    def override_get_db():
        yield db_session

    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as c:
        yield c
    app.dependency_overrides.pop(get_db, None)


class TestAdminServersList:
    """Тесты GET /api/admin/servers."""

    def test_servers_response_shape(self, client, admin_token, sample_server):
        """Ответ содержит servers, total, page, limit."""
        response = client.get(
            "/api/admin/servers",
            headers={"Authorization": f"Bearer {admin_token}"},
        )
        assert response.status_code == 200
        data = response.json()
        assert "servers" in data
        assert "total" in data
        assert "page" in data
        assert "limit" in data
        assert isinstance(data["servers"], list)
        assert data["total"] >= 1
        assert data["page"] == 1
        assert data["limit"] == 100
        assert len(data["servers"]) >= 1

    def test_servers_pagination_params(self, client, admin_token):
        """Параметры page и limit применяются."""
        response = client.get(
            "/api/admin/servers",
            params={"page": 2, "limit": 5},
            headers={"Authorization": f"Bearer {admin_token}"},
        )
        assert response.status_code == 200
        data = response.json()
        assert data["page"] == 2
        assert data["limit"] == 5
        assert len(data["servers"]) <= 5

    def test_servers_unauthorized_without_token(self, client):
        """Без токена — 403."""
        response = client.get("/api/admin/servers")
        assert response.status_code == 403

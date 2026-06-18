"""
Тесты API админ-аутентификации: смена пароля.
"""
import pytest
from fastapi.testclient import TestClient

from models.user import User, UserRole
from services.auth_service import AuthService
from core.database import get_db


@pytest.fixture
def admin_user(db_session):
    """Админ с паролем для тестов смены пароля."""
    user = User(
        email="admin@test.local",
        password_hash=AuthService.hash_password("OldPass123"),
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
def client(db_session):
    """TestClient с подменой get_db на тестовую сессию."""
    from main import app

    def override_get_db():
        yield db_session

    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as c:
        yield c
    app.dependency_overrides.pop(get_db, None)


class TestAdminChangePassword:
    """Тесты POST /api/admin/auth/change-password."""

    def test_change_password_success(self, client, admin_token):
        """Успешная смена пароля."""
        response = client.post(
            "/api/admin/auth/change-password",
            json={"current_password": "OldPass123", "new_password": "NewPass456"},
            headers={"Authorization": f"Bearer {admin_token}"},
        )
        assert response.status_code == 200
        assert "message" in response.json()

    def test_change_password_wrong_current(self, client, admin_token):
        """Неверный текущий пароль -> 400."""
        response = client.post(
            "/api/admin/auth/change-password",
            json={"current_password": "WrongCurrent", "new_password": "NewPass456"},
            headers={"Authorization": f"Bearer {admin_token}"},
        )
        assert response.status_code == 400
        data = response.json()
        assert data.get("detail") or data.get("error", {}).get("message")

    def test_change_password_too_short(self, client, admin_token):
        """Новый пароль короче 8 символов -> 400."""
        response = client.post(
            "/api/admin/auth/change-password",
            json={"current_password": "OldPass123", "new_password": "short"},
            headers={"Authorization": f"Bearer {admin_token}"},
        )
        assert response.status_code == 400

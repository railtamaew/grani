import pytest
from fastapi.testclient import TestClient

from core.database import get_db
from models.user import User
from services.auth_service import AuthService


@pytest.fixture
def user_with_token(db_session):
    user = User(
        email="pushlang@test.local",
        password_hash=AuthService.hash_password("Pass12345"),
        is_active=True,
        is_verified=True,
        auth_provider="email",
    )
    db_session.add(user)
    db_session.commit()
    db_session.refresh(user)
    token = AuthService.create_access_token(user.id)
    return user, token


@pytest.fixture
def client(db_session):
    from main import app

    def override_get_db():
        yield db_session

    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as c:
        yield c
    app.dependency_overrides.pop(get_db, None)


def test_push_token_updates_user_language(client, user_with_token, db_session):
    user, token = user_with_token
    response = client.post(
        "/api/vpn/device/push-token",
        json={"push_token": "fcm-token-123", "language": "ru"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    assert response.json()["ok"] is True
    db_session.refresh(user)
    assert user.push_token == "fcm-token-123"
    assert user.preferred_language == "ru"


def test_push_token_ignores_unsupported_language(client, user_with_token, db_session):
    user, token = user_with_token
    response = client.post(
        "/api/vpn/device/push-token",
        json={"push_token": "fcm-token-456", "language": "de"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    db_session.refresh(user)
    assert user.push_token == "fcm-token-456"
    assert user.preferred_language == "en"


def test_push_token_exclusive_per_user(client, db_session):
    """Один FCM-токен не должен оставаться у двух пользователей — иначе пуш уходит не тому."""
    other = User(
        email="other-push@test.local",
        password_hash=AuthService.hash_password("Pass12345"),
        is_active=True,
        is_verified=True,
        auth_provider="email",
        push_token="shared-fcm-token",
    )
    user = User(
        email="owner-push@test.local",
        password_hash=AuthService.hash_password("Pass12345"),
        is_active=True,
        is_verified=True,
        auth_provider="email",
    )
    db_session.add_all([other, user])
    db_session.commit()
    db_session.refresh(other)
    db_session.refresh(user)
    token = AuthService.create_access_token(user.id)

    response = client.post(
        "/api/vpn/device/push-token",
        json={"push_token": "shared-fcm-token", "language": "en"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    db_session.refresh(other)
    db_session.refresh(user)
    assert other.push_token is None
    assert user.push_token == "shared-fcm-token"

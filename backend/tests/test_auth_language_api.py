import pytest
from fastapi.testclient import TestClient

from core.database import get_db
from models.user import User
from services.auth_service import AuthService


@pytest.fixture
def user_with_token(db_session):
    user = User(
        email="lang@test.local",
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


def test_update_language_success(client, user_with_token, db_session):
    user, token = user_with_token
    response = client.post(
        "/api/auth/language",
        json={"language": "ru"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    assert response.json()["ok"] is True
    assert response.json()["language"] == "ru"

    db_session.refresh(user)
    assert user.preferred_language == "ru"


def test_update_language_invalid_value(client, user_with_token):
    _, token = user_with_token
    response = client.post(
        "/api/auth/language",
        json={"language": "de"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 400


def test_update_language_normalizes_uppercase(client, user_with_token, db_session):
    user, token = user_with_token
    response = client.post(
        "/api/auth/language",
        json={"language": "RU"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    assert response.json()["language"] == "ru"
    db_session.refresh(user)
    assert user.preferred_language == "ru"

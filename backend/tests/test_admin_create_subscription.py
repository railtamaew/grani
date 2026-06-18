"""
Тесты ручного создания подписки через админку: POST /api/admin/users/{user_id}/subscription.
Проверяем приём JSON body (plan_id, end_date, reason) и создание подписки.
"""
import pytest
from datetime import datetime, timedelta
from fastapi.testclient import TestClient

from models.user import User, UserRole
from models.subscription import Plan, Subscription
from services.auth_service import AuthService
from core.database import get_db


@pytest.fixture
def admin_user(db_session):
    """Админ для вызова create subscription."""
    user = User(
        email="admin@sub.test",
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
def target_user(db_session):
    """Пользователь, которому создаём подписку."""
    user = User(
        email="user@sub.test",
        password_hash=None,
        is_active=True,
        auth_provider="email",
    )
    db_session.add(user)
    db_session.commit()
    db_session.refresh(user)
    return user


@pytest.fixture
def plan(db_session):
    """Тариф для подписки."""
    p = Plan(
        name="1 месяц",
        description="Тестовый тариф",
        price=299.0,
        duration_days=30,
        max_speed_mbps=100,
        max_devices=2,
        is_active=True,
    )
    db_session.add(p)
    db_session.commit()
    db_session.refresh(p)
    return p


@pytest.fixture
def client(db_session, admin_user, target_user, plan):
    """TestClient с подменой get_db."""
    from main import app

    def override_get_db():
        yield db_session

    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as c:
        yield c
    app.dependency_overrides.pop(get_db, None)


def _auth_headers(admin_user):
    token = AuthService.create_access_token(admin_user.id)
    return {"Authorization": f"Bearer {token}"}


def test_create_subscription_success(client, admin_user, target_user, plan, db_session):
    """Успешное создание подписки по JSON body (как шлёт админка)."""
    end_date = (datetime.utcnow() + timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%S")
    response = client.post(
        f"/api/admin/users/{target_user.id}/subscription",
        json={
            "plan_id": plan.id,
            "end_date": end_date,
            "reason": "Тестовая выдача",
        },
        headers=_auth_headers(admin_user),
    )
    assert response.status_code == 200
    data = response.json()
    assert data["message"] == "Подписка создана"
    assert "subscription_id" in data

    sub = db_session.query(Subscription).filter(Subscription.user_id == target_user.id).first()
    assert sub is not None
    assert sub.plan_id == plan.id
    assert sub.status == "active"
    assert sub.source == "manual"


def test_create_subscription_end_date_datetime_local_format(client, admin_user, target_user, plan, db_session):
    """Формат даты как от input datetime-local: 2026-02-15T16:09 (без секунд)."""
    response = client.post(
        f"/api/admin/users/{target_user.id}/subscription",
        json={
            "plan_id": plan.id,
            "end_date": "2026-02-15T16:09",
            "reason": "",
        },
        headers=_auth_headers(admin_user),
    )
    assert response.status_code == 200
    sub = db_session.query(Subscription).filter(Subscription.user_id == target_user.id).first()
    assert sub is not None
    assert sub.end_date.year == 2026
    assert sub.end_date.month == 2
    assert sub.end_date.day == 15
    assert sub.end_date.hour == 16
    assert sub.end_date.minute == 9


def _error_message(response):
    """Извлечь текст ошибки из ответа (detail или error.message)."""
    data = response.json()
    if "detail" in data:
        return (data["detail"] or "").lower()
    if "error" in data and isinstance(data["error"], dict):
        return (data["error"].get("message") or "").lower()
    return ""


def test_create_subscription_user_not_found(client, admin_user, plan):
    """404 при несуществующем user_id."""
    response = client.post(
        "/api/admin/users/99999/subscription",
        json={"plan_id": plan.id, "end_date": "2026-12-31T23:59:59", "reason": ""},
        headers=_auth_headers(admin_user),
    )
    assert response.status_code == 404
    msg = _error_message(response)
    assert "не найден" in msg or "not found" in msg


def test_create_subscription_plan_not_found(client, admin_user, target_user):
    """404 при несуществующем plan_id."""
    response = client.post(
        f"/api/admin/users/{target_user.id}/subscription",
        json={"plan_id": 99999, "end_date": "2026-12-31T23:59:59", "reason": ""},
        headers=_auth_headers(admin_user),
    )
    assert response.status_code == 404
    msg = _error_message(response)
    assert "тариф" in msg or "plan" in msg


def test_create_subscription_requires_auth(client, target_user, plan):
    """401/403 без токена."""
    response = client.post(
        f"/api/admin/users/{target_user.id}/subscription",
        json={"plan_id": plan.id, "end_date": "2026-12-31T23:59:59", "reason": ""},
    )
    assert response.status_code in (401, 403)


def test_create_subscription_invalid_body(client, admin_user, target_user):
    """422 при невалидном body (например без plan_id)."""
    response = client.post(
        f"/api/admin/users/{target_user.id}/subscription",
        json={"end_date": "2026-12-31T23:59:59", "reason": ""},
        headers=_auth_headers(admin_user),
    )
    assert response.status_code == 422

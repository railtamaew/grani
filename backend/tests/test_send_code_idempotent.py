"""
Идемпотентность POST /api/auth/send-code: повтор при уже активном коде не создаёт дубликат.
"""
import pytest
from fastapi.testclient import TestClient

from core.database import get_db
from main import app


@pytest.fixture
def client(db_session):
    def override_get_db():
        yield db_session

    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as c:
        yield c
    app.dependency_overrides.pop(get_db, None)


class TestSendCodeIdempotent:
    def test_second_send_code_deduplicated_same_request_id(self, client):
        email = "idem-send-code@example.com"
        r1 = client.post("/api/auth/send-code", json={"email": email})
        assert r1.status_code == 200, r1.text
        j1 = r1.json()
        assert j1.get("ok") is True
        rid1 = j1.get("request_id")
        assert rid1 is not None
        assert j1.get("deduplicated") is not True

        r2 = client.post("/api/auth/send-code", json={"email": email})
        assert r2.status_code == 200, r2.text
        j2 = r2.json()
        assert j2.get("ok") is True
        assert j2.get("deduplicated") is True
        assert j2.get("request_id") == rid1

    def test_force_resend_issues_new_code(self, client):
        email = "idem-force@example.com"
        r1 = client.post("/api/auth/send-code", json={"email": email})
        assert r1.status_code == 200
        assert r1.json().get("deduplicated") is not True

        r2 = client.post(
            "/api/auth/send-code",
            json={"email": email, "force_resend": True},
        )
        assert r2.status_code == 200, r2.text
        j2 = r2.json()
        assert j2.get("ok") is True
        # Явный resend не считается идемпотентным ответом — новый код и письмо
        assert j2.get("deduplicated") is not True

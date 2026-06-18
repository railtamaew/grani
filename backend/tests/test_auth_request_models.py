"""
Тесты для моделей запросов авторизации.
"""
import pytest
from pydantic import ValidationError

from api.auth import SendCodeRequest


def test_send_code_request_valid_email():
    req = SendCodeRequest(email="user@example.com")
    assert req.email == "user@example.com"


@pytest.mark.parametrize("bad_email", ["invalid", "user@", "user@domain", "user@domain."])
def test_send_code_request_invalid_email(bad_email):
    with pytest.raises(ValidationError):
        SendCodeRequest(email=bad_email)

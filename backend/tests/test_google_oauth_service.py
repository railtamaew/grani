"""
Тесты для вспомогательных функций Google OAuth.
"""
from services.google_oauth_service import _parse_max_age, DEFAULT_JWKS_TTL_SECONDS


def test_parse_max_age_none_returns_default():
    assert _parse_max_age(None) == DEFAULT_JWKS_TTL_SECONDS


def test_parse_max_age_missing_returns_default():
    assert _parse_max_age("public, must-revalidate") == DEFAULT_JWKS_TTL_SECONDS


def test_parse_max_age_invalid_returns_default():
    assert _parse_max_age("max-age=notanumber") == DEFAULT_JWKS_TTL_SECONDS


def test_parse_max_age_valid_returns_value():
    assert _parse_max_age("public, max-age=7200") == 7200

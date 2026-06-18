import json
import logging
import re
import time
from dataclasses import dataclass
from typing import Dict, List, Optional

import jwt
import requests

logger = logging.getLogger(__name__)

GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs"
DEFAULT_JWKS_TTL_SECONDS = 3600

_jwks_cache: Dict[str, object] = {
    "expires_at": 0,
    "keys": [],
}


@dataclass
class GoogleOAuthError(Exception):
    message: str
    code: str = "GOOGLE_OAUTH_ERROR"

    def __str__(self) -> str:
        return self.message


def _parse_max_age(cache_control: Optional[str]) -> int:
    if not cache_control:
        return DEFAULT_JWKS_TTL_SECONDS
    match = re.search(r"max-age=(\d+)", cache_control)
    if not match:
        return DEFAULT_JWKS_TTL_SECONDS
    try:
        return int(match.group(1))
    except ValueError:
        return DEFAULT_JWKS_TTL_SECONDS


def _fetch_jwks() -> List[Dict[str, object]]:
    try:
        response = requests.get(GOOGLE_JWKS_URL, timeout=10)
        response.raise_for_status()
    except Exception as exc:
        logger.error("Google OAuth: failed to fetch JWKS: %s", exc)
        raise GoogleOAuthError("Не удалось получить ключи Google OAuth")

    jwks = response.json()
    keys = jwks.get("keys", [])
    if not keys:
        raise GoogleOAuthError("Пустой список ключей Google OAuth")

    ttl = _parse_max_age(response.headers.get("cache-control"))
    _jwks_cache["keys"] = keys
    _jwks_cache["expires_at"] = time.time() + ttl
    return keys


def _get_jwks_keys() -> List[Dict[str, object]]:
    if _jwks_cache["keys"] and time.time() < _jwks_cache["expires_at"]:
        return _jwks_cache["keys"]
    return _fetch_jwks()


def warm_jwks_cache() -> None:
    """Pre-fetch JWKS on startup to avoid cold latency on first Google auth."""
    try:
        _get_jwks_keys()
        logger.info("Google OAuth: JWKS cache warmed on startup")
    except Exception as e:
        logger.warning("Google OAuth: JWKS pre-fetch failed (will retry on first auth): %s", e)


def verify_google_id_token(id_token: str, allowed_client_ids: List[str]) -> Dict[str, object]:
    if not allowed_client_ids:
        raise GoogleOAuthError("Список client_id для Google OAuth не настроен")

    try:
        header = jwt.get_unverified_header(id_token)
    except Exception as exc:
        logger.warning("Google OAuth: invalid token header: %s", exc)
        raise GoogleOAuthError("Некорректный Google ID token")

    kid = header.get("kid")
    if not kid:
        raise GoogleOAuthError("Отсутствует kid в заголовке Google ID token")

    keys = _get_jwks_keys()
    key = next((k for k in keys if k.get("kid") == kid), None)
    if key is None:
        # попробуем обновить JWKS один раз
        keys = _fetch_jwks()
        key = next((k for k in keys if k.get("kid") == kid), None)
        if key is None:
            raise GoogleOAuthError("Ключ для Google ID token не найден")

    try:
        public_key = jwt.algorithms.RSAAlgorithm.from_jwk(json.dumps(key))
        payload = jwt.decode(
            id_token,
            key=public_key,
            algorithms=["RS256"],
            audience=allowed_client_ids,
            issuer=["https://accounts.google.com", "accounts.google.com"],
        )
    except jwt.ExpiredSignatureError:
        raise GoogleOAuthError("Google ID token истек", code="TOKEN_EXPIRED")
    except jwt.InvalidTokenError:
        raise GoogleOAuthError("Google ID token недействителен", code="TOKEN_INVALID")
    except Exception as exc:
        logger.error("Google OAuth: token decode error: %s", exc)
        raise GoogleOAuthError("Не удалось проверить Google ID token")

    return payload

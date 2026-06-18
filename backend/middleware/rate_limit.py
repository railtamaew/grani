"""
Rate limiting middleware для защиты от спама и brute force атак.
"""
import logging
from datetime import datetime, timedelta
from typing import Callable, Optional

from fastapi import Request, HTTPException, status

from core.error_types import ErrorCode
from core.rate_limit_store import RateLimitStore, get_rate_limit_store
from core.config import settings

logger = logging.getLogger(__name__)


def _default_store() -> RateLimitStore:
    """Lazy default store from config."""
    from core.config import settings
    store_type = getattr(settings, "rate_limit_store", "memory")
    redis_url = getattr(settings, "redis_url", None)
    return get_rate_limit_store(store_type, redis_url)


class RateLimiter:
    """
    Rate limiter for endpoints. Uses configurable store (memory or Redis).
    """

    def __init__(
        self,
        calls: int = 5,
        period: int = 60,
        key_func: Optional[Callable[[Request], str]] = None,
        store: Optional[RateLimitStore] = None,
    ):
        self.calls = calls
        self.period = period
        self.key_func = key_func or self._default_key_func
        self._store = store if store is not None else _default_store()

    def _default_key_func(self, request: Request) -> str:
        client_ip = request.client.host if request.client else "unknown"
        path = request.url.path
        return f"{client_ip}:{path}"

    def _get_key(self, request: Request) -> str:
        return self.key_func(request)

    def check_rate_limit(self, request: Request) -> bool:
        if getattr(settings, "disable_rate_limit", False):
            return True
        key = self._get_key(request)
        count = self._store.count_recent(key, self.period)
        if count >= self.calls:
            logger.warning("Rate limit exceeded for %s: %s requests in %ss", key, count, self.period)
            return False
        self._store.add_timestamp(key, self.period)
        return True

    def get_remaining(self, request: Request) -> int:
        key = self._get_key(request)
        count = self._store.count_recent(key, self.period)
        return max(0, self.calls - count)

    def get_reset_time(self, request: Request) -> Optional[datetime]:
        key = self._get_key(request)
        oldest = self._store.get_oldest_timestamp(key, self.period)
        if oldest is None:
            return None
        return datetime.fromtimestamp(oldest) + timedelta(seconds=self.period)


def create_rate_limit_dependency(
    calls: int = 5,
    period: int = 60,
    key_func: Optional[Callable[[Request], str]] = None
):
    """
    Создает dependency для rate limiting в FastAPI endpoints.
    
    Usage:
        @router.post("/send-code")
        async def send_code(
            request: Request,
            rate_limit: None = Depends(create_rate_limit_dependency(calls=5, period=60))
        ):
            ...
    """
    limiter = RateLimiter(calls=calls, period=period, key_func=key_func)
    
    def rate_limit_check(request: Request):
        if not limiter.check_rate_limit(request):
            remaining = limiter.get_remaining(request)
            reset_time = limiter.get_reset_time(request)
            
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail={
                    "error": {
                        "code": ErrorCode.RATE_LIMIT_EXCEEDED.value,
                        "message": f"Превышен лимит запросов. Разрешено {limiter.calls} запросов в {limiter.period} секунд.",
                        "remaining": remaining,
                        "reset_at": reset_time.isoformat() if reset_time else None
                    }
                },
                headers={
                    "X-RateLimit-Limit": str(limiter.calls),
                    "X-RateLimit-Remaining": str(remaining),
                    "X-RateLimit-Reset": str(int(reset_time.timestamp())) if reset_time else ""
                }
            )
        return None
    
    return rate_limit_check


def create_email_rate_limit_dependency():
    """
    Создает dependency для rate limiting отправки кодов на email.
    
    Лимиты:
    - 5 запросов в минуту на IP адрес
    - 3 запроса в минуту на email адрес
    """
    def email_key_func(request: Request) -> str:
        """Генерирует ключ на основе IP и email"""
        client_ip = request.client.host if request.client else "unknown"
        
        # Пытаемся получить email из тела запроса
        # Это будет работать только если request уже прочитан
        email = getattr(request.state, 'email', None)
        if email:
            return f"{client_ip}:email:{email}"
        return f"{client_ip}:send-code"
    
    # Лимит: 5 запросов в минуту на IP
    ip_limiter = RateLimiter(calls=5, period=60)
    
    # Лимит: 3 запроса в минуту на email (будет применен в endpoint)
    email_limiter = RateLimiter(calls=3, period=60, key_func=email_key_func)
    
    def rate_limit_check(request: Request):
        # Проверяем лимит по IP
        if not ip_limiter.check_rate_limit(request):
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail={
                    "error": {
                        "code": ErrorCode.RATE_LIMIT_EXCEEDED.value,
                        "message": "Превышен лимит запросов с вашего IP адреса. Попробуйте позже."
                    }
                }
            )
        return None
    
    return rate_limit_check, email_limiter


def create_verify_code_rate_limit_dependency():
    """
    Создает dependency для rate limiting проверки кодов.
    
    Лимиты:
    - 10 попыток в минуту на IP адрес
    - 5 попыток в минуту на email адрес
    """
    def email_key_func(request: Request) -> str:
        """Генерирует ключ на основе IP и email"""
        client_ip = request.client.host if request.client else "unknown"
        email = getattr(request.state, 'email', None)
        if email:
            return f"{client_ip}:email:{email}:verify"
        return f"{client_ip}:verify-code"
    
    # Лимит: 10 попыток в минуту на IP
    ip_limiter = RateLimiter(calls=10, period=60)
    
    # Лимит: 5 попыток в минуту на email
    email_limiter = RateLimiter(calls=5, period=60, key_func=email_key_func)
    
    def rate_limit_check(request: Request):
        # Проверяем лимит по IP
        if not ip_limiter.check_rate_limit(request):
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail={
                    "error": {
                        "code": ErrorCode.RATE_LIMIT_EXCEEDED.value,
                        "message": "Превышен лимит попыток проверки кода. Попробуйте позже."
                    }
                }
            )
        return None
    
    return rate_limit_check, email_limiter

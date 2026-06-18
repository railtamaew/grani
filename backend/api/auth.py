from fastapi import APIRouter, Depends, HTTPException, status, BackgroundTasks, Request, Request as FastAPIRequest
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.orm import Session
from datetime import datetime, timedelta
from typing import Optional
import time
from pydantic import BaseModel, EmailStr
from sqlalchemy import func

from core.database import get_db
from core.request_context import get_request_id
from core.config import settings
from core.async_utils import run_sync
from core.constants import (
    AUTH_SEND_CODE_RATE_LIMIT_IP,
    AUTH_SEND_CODE_RATE_LIMIT_EMAIL,
    AUTH_VERIFY_CODE_RATE_LIMIT_IP,
    AUTH_VERIFY_CODE_RATE_LIMIT_EMAIL,
    AUTH_RATE_LIMIT_PERIOD_SECONDS
)
from models.user import User
from models.auth_code import AuthCode
from services.auth_service import AuthService
from services.trial_service import get_user_access_info, get_active_subscription_details
from services.google_oauth_service import verify_google_id_token, GoogleOAuthError
from services.code_service import (
    generate_code,
    hash_code,
    verify_code,
    create_auth_code,
    get_auth_code,
    get_active_auth_codes,
    increment_attempts,
    delete_auth_code,
    acquire_send_code_lock,
    EMAIL_CODE_TTL_MINUTES,
    MAX_VERIFICATION_ATTEMPTS,
)
from middleware.rate_limit import RateLimiter
from core.logging_utils import safe_log_value, mask_sensitive_string
from core.http_diag import format_request_diag
from core.perf_logging import perf_logger
# Ленивый импорт aws_ses_service - импортируем только при необходимости
import logging

logger = logging.getLogger(__name__)


def _perf_req_id(http_request: FastAPIRequest) -> str:
    return (
        http_request.headers.get("X-Request-ID")
        or http_request.headers.get("x-request-id")
        or "-"
    )


# Инициализация rate limiters для auth endpoints
_send_code_ip_limiter = RateLimiter(
    calls=AUTH_SEND_CODE_RATE_LIMIT_IP,
    period=AUTH_RATE_LIMIT_PERIOD_SECONDS
)

def _send_code_email_key_func(request: Request) -> str:
    """Генерирует ключ для rate limiting по email для отправки кода"""
    email = getattr(request.state, 'email', 'unknown')
    return f"email:{email}"

_send_code_email_limiter = RateLimiter(
    calls=AUTH_SEND_CODE_RATE_LIMIT_EMAIL,
    period=AUTH_RATE_LIMIT_PERIOD_SECONDS,
    key_func=_send_code_email_key_func
)

_verify_code_ip_limiter = RateLimiter(
    calls=AUTH_VERIFY_CODE_RATE_LIMIT_IP,
    period=AUTH_RATE_LIMIT_PERIOD_SECONDS
)

def _verify_code_email_key_func(request: Request) -> str:
    """Генерирует ключ для rate limiting по email для проверки кода"""
    email = getattr(request.state, 'email', 'unknown')
    return f"email:{email}:verify"

_verify_code_email_limiter = RateLimiter(
    calls=AUTH_VERIFY_CODE_RATE_LIMIT_EMAIL,
    period=AUTH_RATE_LIMIT_PERIOD_SECONDS,
    key_func=_verify_code_email_key_func
)

router = APIRouter()
security = HTTPBearer()


def _send_code_email_task(email: str, code: str, language: str = "en") -> None:
    """
    Background-задача: отправка email с кодом.
    Выполняется после ответа клиенту, чтобы не блокировать latency /auth/send-code.
    """
    try:
        from services.email_service import send_verification_email
        logger.info(f"[send-code-task] Отправка email для {email}")
        ok = send_verification_email(
            to_email=email,
            verification_code=code,
            language=language,
        )
        if ok:
            logger.info(f"[send-code-task] Email успешно отправлен для {email}")
        else:
            logger.error(f"[send-code-task] Не удалось отправить email для {email}")
    except Exception as e:
        logger.error(f"[send-code-task] Исключение при отправке email для {email}: {e}", exc_info=True)

# Pydantic модели
class SendCodeRequest(BaseModel):
    email: EmailStr
    force_resend: bool = False

class VerifyCodeRequest(BaseModel):
    email: EmailStr
    code: str
    request_id: Optional[str] = None

class RefreshTokenRequest(BaseModel):
    refresh_token: str

class GoogleCallbackRequest(BaseModel):
    id_token: str
    access_token: Optional[str] = None

class LanguageUpdateRequest(BaseModel):
    language: str


def _is_play_review_email(email: str) -> bool:
    configured = (settings.play_review_email or "").lower().strip()
    return bool(configured) and email.lower().strip() == configured


def _play_review_code() -> Optional[str]:
    code = (settings.play_review_code or "").strip()
    return code or None

# Эндпоинт отправки кода
@router.post("/send-code")
async def send_code(
    request: SendCodeRequest,
    background_tasks: BackgroundTasks,
    http_request: FastAPIRequest,
    db: Session = Depends(get_db)
):
    """
    Отправляет код подтверждения на email.
    Создает или обновляет пользователя, генерирует код, сохраняет его в БД
    и ставит отправку письма в background task, чтобы не блокировать ответ.
    
    Rate limiting:
    - 5 запросов в минуту с одного IP адреса
    - 3 запроса в минуту на один email адрес
    """
    email = request.email.lower().strip()
    force_resend = bool(request.force_resend)
    t0 = time.monotonic()
    req_id = _perf_req_id(http_request)
    start_ts = t0
    try:
        logger.debug(
            "[send-code-req] %s email=%s force_resend=%s",
            format_request_diag(http_request),
            safe_log_value(email),
            force_resend,
        )

        t_rl_ip = time.monotonic()
        if not _send_code_ip_limiter.check_rate_limit(http_request):
            logger.warning(f"[send-code] Rate limit exceeded for IP: {http_request.client.host if http_request.client else 'unknown'}")
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail={
                    "error": {
                        "code": "RATE_LIMIT_EXCEEDED",
                        "message": f"Превышен лимит запросов. Разрешено {AUTH_SEND_CODE_RATE_LIMIT_IP} запросов в минуту с вашего IP адреса."
                    }
                }
            )
        d_ip_ms = (time.monotonic() - t_rl_ip) * 1000

        # Сохраняем email в state для проверки по email
        http_request.state.email = email

        perf_logger.warning(
            "[perf] step=before_db dt_ms=%.1f req_id=%s path=send-code",
            (time.monotonic() - t0) * 1000,
            req_id,
        )
        t_lock = time.monotonic()
        acquire_send_code_lock(db, email)
        perf_logger.warning(
            "[perf] step=after_advisory_lock dt_ms=%.1f lock_only_ms=%.1f req_id=%s path=send-code",
            (time.monotonic() - t0) * 1000,
            (time.monotonic() - t_lock) * 1000,
            req_id,
        )
        existing = get_auth_code(email, db)
        perf_logger.warning(
            "[perf] step=after_db dt_ms=%.1f req_id=%s path=send-code",
            (time.monotonic() - t0) * 1000,
            req_id,
        )

        # Идемпотентность: активный неистёкший код уже есть (например первый запрос дошёл до
        # сервера, а клиент получил таймаут) — не создаём новый код и не шлём второе письмо.
        # Явный force_resend (экран «Отправить код снова») пропускает этот шаг — новый код и письмо.
        if existing and not force_resend:
            perf_logger.warning(
                "[perf] step=rate_limit dt_ms=%.1f req_id=%s path=send-code",
                d_ip_ms,
                req_id,
            )
            logger.debug(
                "[send-code] Идемпотентный ответ: активный код уже есть для %s, id=%s",
                safe_log_value(email),
                existing.id,
            )
            db.rollback()
            return {
                "ok": True,
                "message": "Код уже отправлен. Проверьте почту; при необходимости запросите код позже.",
                "request_id": str(existing.id),
                "deduplicated": True,
            }

        t_rl_em = time.monotonic()
        if not _send_code_email_limiter.check_rate_limit(http_request):
            logger.warning(f"[send-code] Rate limit exceeded for email: {email}")
            db.rollback()
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail={
                    "error": {
                        "code": "RATE_LIMIT_EXCEEDED",
                        "message": f"Превышен лимит запросов для этого email. Разрешено {AUTH_SEND_CODE_RATE_LIMIT_EMAIL} запросов в минуту."
                    }
                }
            )
        d_em_ms = (time.monotonic() - t_rl_em) * 1000
        perf_logger.warning(
            "[perf] step=rate_limit dt_ms=%.1f req_id=%s path=send-code",
            d_ip_ms + d_em_ms,
            req_id,
        )

        # Генерация и хеширование кода.
        # Для Google Play review можно включить стабильный код через env:
        # PLAY_REVIEW_EMAIL + PLAY_REVIEW_CODE. По умолчанию выключено.
        review_code = _play_review_code() if _is_play_review_email(email) else None
        code = review_code or generate_code()
        masked_code = mask_sensitive_string(code, visible_chars=0) if code else "None"
        logger.debug("[send-code] Код сгенерирован для %s: '%s'", safe_log_value(email), masked_code)
        code_hash = hash_code(code)
        expires_at = datetime.utcnow() + timedelta(minutes=EMAIL_CODE_TTL_MINUTES)

        # IP для диагностики
        client_ip = None
        if http_request:
            forwarded_for = http_request.headers.get("X-Forwarded-For")
            if forwarded_for:
                client_ip = forwarded_for.split(",")[0].strip()
            else:
                client_ip = http_request.client.host if http_request.client else None

        # Создаем или получаем пользователя
        user = db.query(User).filter(func.lower(User.email) == email).first()
        if not user:
            user = User(
                email=email,
                password_hash=None,
                is_verified=False,
                auth_provider="email",
                preferred_language="en",
            )
            db.add(user)
            db.flush()
            db.refresh(user)
            logger.debug("[send-code] Создан новый пользователь для %s, id: %s", safe_log_value(email), user.id)
        else:
            logger.debug("[send-code] Найден существующий пользователь для %s, id: %s", safe_log_value(email), user.id)

        # Создаем запись кода в БД (одна операция)
        auth_code = create_auth_code(
            email,
            code_hash,
            expires_at,
            db,
            ip_address=client_ip,
            commit_transaction=False,
        )
        if not auth_code:
            logger.error(f"[send-code] Не удалось создать код в БД для {email}")
            db.rollback()
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="Не удалось создать код подтверждения"
            )
        logger.debug("[send-code] Код сохранён в БД для %s: id=%s", safe_log_value(email), auth_code.id)

        # Ставит отправку письма в background task, чтобы не блокировать ответ.
        background_tasks.add_task(
            _send_code_email_task,
            email,
            code,
            user.preferred_language or "en",
        )
        logger.debug("[send-code] Задача отправки email поставлена в очередь для %s", safe_log_value(email))

        t_commit = time.monotonic()
        db.commit()
        perf_logger.warning(
            "[perf] step=after_commit dt_ms=%.1f commit_ms=%.1f req_id=%s path=send-code",
            (time.monotonic() - t0) * 1000,
            (time.monotonic() - t_commit) * 1000,
            req_id,
        )
        return {
            "ok": True,
            "message": "Код отправлен на email",
            "request_id": str(auth_code.id),
        }

    except HTTPException:
        logger.warning("[send-code] HTTPException при отправке кода для %s", safe_log_value(email))
        raise
    except Exception as e:
        logger.error(f"[send-code] Ошибка при отправке кода для {email}: {e}", exc_info=True)
        try:
            db.rollback()
        except Exception:
            pass
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Ошибка при отправке кода"
        )
    finally:
        try:
            elapsed_ms = int((time.monotonic() - start_ts) * 1000)
            perf_logger.warning(
                "[perf] step=total dt_ms=%.1f req_id=%s path=send-code",
                elapsed_ms,
                req_id,
            )
            logger.warning(
                "[send-code-timing] %s email=%s elapsed_ms=%s",
                format_request_diag(http_request),
                safe_log_value(email),
                elapsed_ms,
            )
        except Exception:
            # Диагностический лог не должен ломать основной поток
            pass

# Эндпоинт проверки кода
@router.post("/verify-code")
async def verify_code_endpoint(
    request: VerifyCodeRequest,
    http_request: FastAPIRequest,
    db: Session = Depends(get_db)
):
    """
    Проверяет код подтверждения и авторизует пользователя.
    Возвращает JWT токен и данные пользователя.
    
    Rate limiting:
    - 10 попыток в минуту с одного IP адреса
    - 5 попыток в минуту на один email адрес
    """
    t0 = time.monotonic()
    req_id = _perf_req_id(http_request)
    start_ts = t0
    email = ""
    try:
        email = request.email.lower().strip()

        # Сохраняем email в state для проверки по email
        http_request.state.email = email
        logger.debug(
            "[verify-code-req] %s email=%s",
            format_request_diag(http_request),
            safe_log_value(email),
        )

        t_rl_ip = time.monotonic()
        if not _verify_code_ip_limiter.check_rate_limit(http_request):
            logger.warning(f"[verify-code] Rate limit exceeded for IP: {http_request.client.host if http_request.client else 'unknown'}")
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail={
                    "error": {
                        "code": "RATE_LIMIT_EXCEEDED",
                        "message": f"Превышен лимит попыток. Разрешено {AUTH_VERIFY_CODE_RATE_LIMIT_IP} попыток в минуту с вашего IP адреса."
                    }
                }
            )
        d_ip_ms = (time.monotonic() - t_rl_ip) * 1000

        t_rl_em = time.monotonic()
        if not _verify_code_email_limiter.check_rate_limit(http_request):
            logger.warning(f"[verify-code] Rate limit exceeded for email: {email}")
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail={
                    "error": {
                        "code": "RATE_LIMIT_EXCEEDED",
                        "message": f"Превышен лимит попыток для этого email. Разрешено {AUTH_VERIFY_CODE_RATE_LIMIT_EMAIL} попыток в минуту."
                    }
                }
            )
        d_em_ms = (time.monotonic() - t_rl_em) * 1000
        perf_logger.warning(
            "[perf] step=rate_limit dt_ms=%.1f req_id=%s path=verify-code",
            d_ip_ms + d_em_ms,
            req_id,
        )

        original_code = request.code
        code = original_code if original_code else ""

        perf_logger.warning(
            "[perf] step=before_db dt_ms=%.1f req_id=%s path=verify-code",
            (time.monotonic() - t0) * 1000,
            req_id,
        )
        auth_codes = get_active_auth_codes(email, db)
        perf_logger.warning(
            "[perf] step=after_db dt_ms=%.1f req_id=%s path=verify-code",
            (time.monotonic() - t0) * 1000,
            req_id,
        )

        if not auth_codes:
            logger.warning("[verify-code] Код не найден или истек для %s", safe_log_value(email))
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Код не найден или истек. Запросите новый код."
            )

        request_id_raw = (request.request_id or "").strip()
        if request_id_raw:
            try:
                request_id_int = int(request_id_raw)
            except ValueError:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="Некорректный request_id. Запросите новый код."
                )
            scoped_codes = [c for c in auth_codes if c.id == request_id_int]
            if not scoped_codes:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="Код не найден или истек. Запросите новый код."
                )
            auth_codes = scoped_codes

        latest_auth_code = auth_codes[0]
        logger.debug(
            "[verify-code] активных кодов=%s last_id=%s attempts=%s",
            len(auth_codes),
            latest_auth_code.id,
            latest_auth_code.attempts_count,
        )

        if latest_auth_code.attempts_count >= MAX_VERIFICATION_ATTEMPTS:
            logger.warning(f"[verify-code] Превышено количество попыток для {email}, attempts: {latest_auth_code.attempts_count}")
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail="Слишком много попыток. Запросите новый код."
            )

        code_str = str(code) if code is not None else ""

        verification_result = False
        matched_auth_code = None
        for candidate in auth_codes:
            if verify_code(code_str, candidate.code_hash):
                verification_result = True
                matched_auth_code = candidate
                break
        logger.debug(
            "[verify-code] match=%s matched_code_id=%s",
            verification_result,
            matched_auth_code.id if matched_auth_code else None,
        )

        if not verification_result:
            try:
                latest_auth_code.attempts_count += 1
                db.commit()
            except Exception:
                db.rollback()
                increment_attempts(email, db)
            logger.warning("[verify-code] Неверный код для %s", safe_log_value(email))
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Неверный код"
            )

        user = db.query(User).filter(func.lower(User.email) == email).first()

        if not user:
            user = User(
                email=email,
                password_hash=None,  # Для email auth пароль не нужен
                is_verified=True,  # Верифицируем после успешной проверки кода
                auth_provider="email",
            )
            db.add(user)
            db.commit()
            db.refresh(user)
            logger.debug("[verify-code] Создан пользователь %s id=%s", safe_log_value(email), user.id)
        else:
            if not user.is_verified:
                user.is_verified = True
                db.commit()
                db.refresh(user)
                logger.debug("[verify-code] Пользователь верифицирован %s", safe_log_value(email))

        delete_auth_code(email, db)

        token = AuthService.create_access_token(user.id)
        refresh_token = AuthService.create_refresh_token(user.id)
        logger.debug(
            "[verify-code] Токены созданы access_len=%s refresh_len=%s",
            len(token) if token else 0,
            len(refresh_token) if refresh_token else 0,
        )

        trial_seconds_left, has_active_subscription = get_user_access_info(user.id, db)
        
        return {
            "ok": True,
            "token": token,
            "access_token": token,  # Для совместимости
            "refresh_token": refresh_token,  # Refresh token для автоматического обновления
            "user": {
                "id": user.id,
                "email": user.email,
                "name": email.split('@')[0],  # Используем часть email до @ как имя
                "is_verified": user.is_verified,
                "created_at": user.created_at.isoformat() if user.created_at else datetime.utcnow().isoformat(),
                "is_blocked": not user.is_active,
                "preferred_language": user.preferred_language or "en",
            },
            "trialSecondsLeft": trial_seconds_left,
            "trial_seconds_left": trial_seconds_left,  # Для совместимости
            "hasActiveSubscription": has_active_subscription,
            "has_active_subscription": has_active_subscription,  # Для совместимости
        }
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(
            "[verify-code] Ошибка при проверке кода для %s: %s",
            safe_log_value(email or "unknown"),
            e,
            exc_info=True,
        )
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Ошибка при проверке кода"
        )
    finally:
        try:
            elapsed_ms = int((time.monotonic() - start_ts) * 1000)
            email_log = (request.email.lower().strip() if request and getattr(request, "email", None) else "unknown")
            perf_logger.warning(
                "[perf] step=total dt_ms=%.1f req_id=%s path=verify-code",
                float(elapsed_ms),
                req_id,
            )
            logger.warning(
                "[verify-code-timing] %s email=%s elapsed_ms=%s",
                format_request_diag(http_request),
                safe_log_value(email_log),
                elapsed_ms,
            )
        except Exception:
            # Диагностический лог не должен ломать основной поток
            pass

@router.post("/google/callback")
async def google_callback(
    request: GoogleCallbackRequest,
    db: Session = Depends(get_db)
):
    """
    Google OAuth callback: проверяет id_token и выдает JWT.
    Объединяет пользователей по email, не создает дубликаты.
    """
    logger.info("[google-callback] ========== ЗАПРОС ПОЛУЧЕН ==========")
    try:
        logger.info("[google-callback] Проверка id_token (длина: %s)", len(request.id_token) if request.id_token else 0)
        if not getattr(settings, "allowed_google_client_ids", None):
            logger.error("[google-callback] allowed_google_client_ids не настроен")
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="Сервер: OAuth не настроен"
            )

        payload = verify_google_id_token(request.id_token, settings.allowed_google_client_ids)

        email = (payload.get("email") or "").lower().strip()
        email_verified = payload.get("email_verified")
        provider_uid = payload.get("sub")
        display_name = payload.get("name") or ""

        if not email or not provider_uid:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Не удалось получить email или sub из Google токена"
            )

        if email_verified is not True:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Email Google аккаунта не подтвержден"
            )

        # Проверяем конфликт provider_uid с другим email
        user_by_provider = db.query(User).filter(User.provider_uid == provider_uid).first()
        if user_by_provider and user_by_provider.email.lower() != email:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Google аккаунт уже привязан к другому email"
            )

        # Ищем пользователя по email (объединение по email)
        user = db.query(User).filter(func.lower(User.email) == email).first()
        if user:
            logger.info("[google-callback] Найден пользователь по email: %s (id=%s)", email, user.id)
            user.provider_uid = provider_uid
            user.auth_provider = "google"
            if not user.is_verified:
                user.is_verified = True
            user.last_login_at = datetime.utcnow()
            db.commit()
            db.refresh(user)
        else:
            logger.info("[google-callback] Пользователь по email не найден, создаем нового: %s", email)
            user = User(
                email=email,
                password_hash=None,
                is_verified=True,
                auth_provider="google",
                provider_uid=provider_uid,
                preferred_language="en",
            )
            db.add(user)
            db.commit()
            db.refresh(user)

        # Создаем токены (access и refresh)
        token = AuthService.create_access_token(user.id)
        refresh_token = AuthService.create_refresh_token(user.id)
        logger.info("[google-callback] Токены созданы, access_token длина: %s, refresh_token длина: %s",
                    len(token) if token else 0, len(refresh_token) if refresh_token else 0)

        # Получаем информацию о подписке и триале из единого сервиса доступа.
        trial_seconds_left, has_active_subscription = get_user_access_info(user.id, db)

        user_name = display_name or email.split("@")[0]

        logger.info("[google-callback] ✅ Успешная авторизация Google для %s, user_id=%s", email, user.id)

        return {
            "ok": True,
            "token": token,
            "access_token": token,
            "refresh_token": refresh_token,
            "user_id": user.id,
            "user": {
                "id": user.id,
                "email": user.email,
                "name": user_name,
                "is_verified": user.is_verified,
                "created_at": user.created_at.isoformat() if user.created_at else datetime.utcnow().isoformat(),
                "is_blocked": not user.is_active,
                "preferred_language": user.preferred_language or "en",
            },
            "trialSecondsLeft": trial_seconds_left,
            "trial_seconds_left": trial_seconds_left,
            "hasActiveSubscription": has_active_subscription,
            "has_active_subscription": has_active_subscription,
        }
    except GoogleOAuthError as e:
        logger.error("[google-callback] Ошибка Google OAuth: %s", e)
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(e)
        )
    except HTTPException:
        raise
    except Exception as e:
        logger.error("[google-callback] Неизвестная ошибка: %s", e, exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Ошибка авторизации через Google"
        )

@router.get("/me")
async def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db)
):
    """Возвращает информацию о текущем пользователе и статусе доступа."""
    try:
        user = AuthService.get_current_user(credentials.credentials, db)
        trial_seconds_left, has_active_subscription = get_user_access_info(user.id, db)
        sub_details = get_active_subscription_details(user.id, db)

        return {
            "id": user.id,
            "email": user.email,
            "is_active": user.is_active,
            "is_verified": user.is_verified,
            "auth_provider": user.auth_provider,
            "preferred_language": user.preferred_language or "en",
            "created_at": user.created_at.isoformat() if user.created_at else None,
            "updated_at": user.updated_at.isoformat() if user.updated_at else None,
            "trialSecondsLeft": trial_seconds_left,
            "trial_seconds_left": trial_seconds_left,
            "hasActiveSubscription": has_active_subscription,
            "has_active_subscription": has_active_subscription,
            **sub_details,
        }
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"[me] Ошибка получения пользователя: {e}", exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Ошибка получения профиля"
        )

@router.post("/language")
async def update_preferred_language(
    request: LanguageUpdateRequest,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
):
    """Обновление предпочитаемого языка пользователя (en/ru)."""
    language = (request.language or "").strip().lower()
    if language not in {"en", "ru"}:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Unsupported language. Use 'en' or 'ru'.",
        )

    user = AuthService.get_current_user(credentials.credentials, db)
    db_user = db.query(User).filter(User.id == user.id).first()
    if not db_user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Пользователь не найден",
        )

    db_user.preferred_language = language
    db.commit()
    return {"ok": True, "language": language}

# Тестовый эндпоинт для проверки отправки email
class TestEmailRequest(BaseModel):
    email: EmailStr
    code: Optional[str] = None

@router.post("/test-email")
async def test_email_sending(
    request: TestEmailRequest,
    db: Session = Depends(get_db)
):
    """
    Тестовый эндпоинт для проверки отправки email без создания кода в БД.
    Полезен для отладки проблем с отправкой email.
    """
    try:
        email = request.email.lower().strip()
        test_code = request.code or "9999"  # По умолчанию используем тестовый код
        
        logger.info(f"[test-email] Тестовая отправка email на {email} с кодом {test_code}")
        
        # Отправляем email через services.email_service (в thread pool, чтобы не блокировать event loop)
        try:
            from services.email_service import send_verification_email

            logger.info(f"[test-email] Вызов send_verification_email для {email}")
            email_sent = await run_sync(
                send_verification_email,
                to_email=email,
                verification_code=test_code,
            )
            
            if email_sent:
                logger.info(f"[test-email] Email успешно отправлен на {email}")
                return {
                    "ok": True,
                    "message": f"Тестовое письмо отправлено на {email}",
                    "code": test_code,
                    "email_sent": True
                }
            else:
                logger.error(f"[test-email] Не удалось отправить email на {email}")
                return {
                    "ok": False,
                    "message": f"Не удалось отправить тестовое письмо на {email}",
                    "code": test_code,
                    "email_sent": False
                }
        except Exception as e:
            logger.error(f"[test-email] Ошибка при отправке тестового email на {email}: {e}", exc_info=True)
            return {
                "ok": False,
                "message": f"Ошибка при отправке тестового email: {str(e)}",
                "code": test_code,
                "email_sent": False,
                "error": str(e)
            }
        
    except Exception as e:
        logger.error(f"[test-email] Ошибка в тестовом эндпоинте: {e}", exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Ошибка при тестировании отправки email: {str(e)}"
        )

@router.post("/refresh-token")
async def refresh_token_endpoint(
    request: RefreshTokenRequest,
    db: Session = Depends(get_db)
):
    """Обновление access token через refresh token"""
    try:
        logger.info(
            "[refresh-token] Запрос req_id=%s",
            get_request_id(),
        )
        
        new_access_token = AuthService.refresh_access_token(request.refresh_token)
        
        if new_access_token is None:
            logger.warning(f"[refresh-token] Неверный или истекший refresh token")
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Неверный или истекший refresh token"
            )
        
        logger.info(f"[refresh-token] ✅ Access token успешно обновлен")
        
        return {
            "access_token": new_access_token,
            "token": new_access_token,  # Для совместимости
            "token_type": "bearer"
        }
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"[refresh-token] Ошибка обновления токена: {e}", exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Ошибка обновления токена"
        )

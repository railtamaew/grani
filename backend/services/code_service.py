"""
Сервис для работы с кодами подтверждения email.
Генерирует коды, хэширует их и управляет записями в таблице auth_codes.
"""
import secrets
import hashlib
import logging
from datetime import datetime, timedelta
from typing import Optional, List
from sqlalchemy.orm import Session
from sqlalchemy import func, text

from models.auth_code import AuthCode
from core.config import settings
from core.constants import EMAIL_CODE_TTL_MINUTES, MAX_VERIFICATION_ATTEMPTS

logger = logging.getLogger(__name__)

EMAIL_CODE_LENGTH = 4  # Длина кода подтверждения

# Второй аргумент pg_advisory_xact_lock — «пространство имён», чтобы не пересечься с другими lock'ами.
_SEND_CODE_ADVISORY_KEY2 = 551_001


def acquire_send_code_lock(db: Session, email: str) -> None:
    """
    Сериализует обработку POST /auth/send-code для одного email в PostgreSQL.
    Иначе два параллельных запроса оба видят отсутствие кода и создают два разных PIN + два письма.
    Для не-PostgreSQL (SQLite в тестах и т.д.) — no-op.
    """
    bind = db.get_bind()
    if bind is None or getattr(bind.dialect, "name", None) != "postgresql":
        return
    normalized = email.lower().strip()
    db.execute(
        text(
            "SELECT pg_advisory_xact_lock(hashtext(CAST(:em AS text)), CAST(:k2 AS int))"
        ),
        {"em": normalized, "k2": _SEND_CODE_ADVISORY_KEY2},
    )


def generate_code() -> str:
    """
    Генерирует 4-значный PIN-код.
    
    Returns:
        Строка с 4 цифрами (например, "1234")
    """
    return "".join(secrets.choice("0123456789") for _ in range(EMAIL_CODE_LENGTH))


def hash_code(code: str) -> str:
    """
    Хэширует код подтверждения.
    Используется SHA-256, так как коды короткие (4 цифры) и нужно быстрое хэширование.
    
    Args:
        code: Код подтверждения (4 цифры)
    
    Returns:
        Хэш кода в hex формате
    """
    # Нормализуем код: удаляем все пробелы и whitespace символы (как в мобильном приложении)
    import re
    normalized_code = re.sub(r'\s+', '', code.strip()) if code else ""
    logger.debug(
        "[code_service.hash_code] len_in=%s len_norm=%s",
        len(code) if code else 0,
        len(normalized_code),
    )
    return hashlib.sha256(normalized_code.encode('utf-8')).hexdigest()


def verify_code(code: str, code_hash: str) -> bool:
    """
    Проверяет, соответствует ли код хэшу.
    
    Args:
        code: Введенный пользователем код
        code_hash: Хэш, сохраненный в базе данных
    
    Returns:
        True если код соответствует хэшу, False иначе
    """
    # Нормализуем код перед проверкой: удаляем все пробелы и whitespace символы (как в мобильном приложении)
    import re
    normalized_code = re.sub(r'\s+', '', code.strip()) if code else ""
    if not normalized_code or not code_hash:
        logger.warning(
            "[code_service.verify_code] Пустой код или хэш: normalized_code=%s code_hash=%s",
            bool(normalized_code),
            bool(code_hash),
        )
        return False

    computed_hash = hash_code(normalized_code)
    result = computed_hash == code_hash
    logger.debug("[code_service.verify_code] match=%s", result)

    if not result:
        logger.warning("[code_service.verify_code] hash mismatch (no hash values logged)")

    return result


def create_auth_code(
    email: str,
    code_hash: str,
    expires_at: datetime,
    db: Session,
    ip_address: Optional[str] = None,
    commit_transaction: bool = True,
) -> Optional[AuthCode]:
    """
    Создает новую запись кода в базе данных.
    Перед созданием удаляет старые коды для этого email.
    
    Args:
        email: Email пользователя
        code_hash: Хэш кода
        expires_at: Время истечения кода
        ip_address: IP адрес, с которого был запрошен код
        db: Сессия базы данных
    
    Returns:
        Созданный объект AuthCode или None в случае ошибки
    """
    try:
        normalized_email = email.lower()
        logger.debug(f"[code_service] Создание кода для {normalized_email}, expires_at: {expires_at}, ip: {ip_address}")
        
        # Удаляем старые коды для этого email
        deleted_count = db.query(AuthCode).filter(
            func.lower(AuthCode.email) == normalized_email
        ).delete()
        if deleted_count > 0:
            logger.debug(f"[code_service] Удалено {deleted_count} старых кодов для {normalized_email}")
        db.flush()
        
        # Создаем новую запись
        auth_code = AuthCode(
            email=normalized_email,
            code_hash=code_hash,
            expires_at=expires_at,
            attempts_count=0,
            ip_address=ip_address,
            created_at=datetime.utcnow()
        )
        db.add(auth_code)
        if commit_transaction:
            db.commit()
            db.refresh(auth_code)
        else:
            db.flush()
            db.refresh(auth_code)

        logger.debug(
            "[code_service] Создан код подтверждения для %s id=%s",
            normalized_email,
            auth_code.id,
        )
        return auth_code

    except Exception as e:
        logger.error(f"Ошибка при создании кода для {email}: {e}")
        db.rollback()
        return None


def get_auth_code(email: str, db: Session) -> Optional[AuthCode]:
    """
    Получает актуальный код подтверждения для email.
    
    Args:
        email: Email пользователя
        db: Сессия базы данных
    
    Returns:
        Объект AuthCode или None, если код не найден или истек
    """
    try:
        normalized_email = email.lower()
        now = datetime.utcnow()
        
        auth_code = db.query(AuthCode).filter(
            func.lower(AuthCode.email) == normalized_email,
            AuthCode.expires_at > now
        ).order_by(AuthCode.created_at.desc()).first()
        
        if auth_code:
            logger.debug(
                "[code_service] Код найден для %s id=%s attempts=%s",
                normalized_email,
                auth_code.id,
                auth_code.attempts_count,
            )
        else:
            logger.warning(f"[code_service] Код не найден или истек для {normalized_email}, now: {now}")
        
        return auth_code
        
    except Exception as e:
        logger.error(f"[code_service] Ошибка при получении кода для {email}: {e}", exc_info=True)
        return None


def get_active_auth_codes(email: str, db: Session) -> List[AuthCode]:
    """
    Возвращает все неистекшие коды для email (сначала самые новые).
    Используется для устойчивой верификации при дублях send-code.
    """
    try:
        normalized_email = email.lower()
        now = datetime.utcnow()

        auth_codes = db.query(AuthCode).filter(
            func.lower(AuthCode.email) == normalized_email,
            AuthCode.expires_at > now
        ).order_by(AuthCode.created_at.desc()).all()

        logger.debug(
            "[code_service] Найдено активных кодов для %s: %s",
            normalized_email,
            len(auth_codes),
        )
        return auth_codes
    except Exception as e:
        logger.error(
            f"[code_service] Ошибка при получении списка кодов для {email}: {e}",
            exc_info=True,
        )
        return []


def increment_attempts(email: str, db: Session) -> bool:
    """
    Увеличивает счетчик попыток ввода кода.
    
    Args:
        email: Email пользователя
        db: Сессия базы данных
    
    Returns:
        True если успешно, False в случае ошибки
    """
    try:
        auth_code = get_auth_code(email, db)
        if auth_code:
            old_attempts = auth_code.attempts_count
            auth_code.attempts_count += 1
            db.commit()
            logger.debug(f"[code_service] Увеличен счетчик попыток для {email}: {old_attempts} -> {auth_code.attempts_count}")
            return True
        logger.warning(f"[code_service] Не удалось увеличить счетчик попыток для {email}: код не найден")
        return False
        
    except Exception as e:
        logger.error(f"[code_service] Ошибка при увеличении счетчика попыток для {email}: {e}", exc_info=True)
        db.rollback()
        return False


def delete_auth_code(email: str, db: Session) -> bool:
    """
    Удаляет код подтверждения для email.
    
    Args:
        email: Email пользователя
        db: Сессия базы данных
    
    Returns:
        True если успешно, False в случае ошибки
    """
    try:
        normalized_email = email.lower()
        deleted = db.query(AuthCode).filter(
            func.lower(AuthCode.email) == normalized_email
        ).delete()
        db.commit()
        if deleted > 0:
            logger.debug(f"[code_service] Удалено {deleted} кодов для {normalized_email}")
        return deleted > 0
        
    except Exception as e:
        logger.error(f"[code_service] Ошибка при удалении кода для {email}: {e}", exc_info=True)
        db.rollback()
        return False


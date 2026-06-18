"""
Сервис для работы с кодами подтверждения email.
Генерирует коды, хэширует их и управляет записями в таблице auth_codes.
"""
import secrets
import hashlib
import logging
from datetime import datetime, timedelta
from typing import Optional
from sqlalchemy.orm import Session
from sqlalchemy import func

from domain.models.auth_code import AuthCode
from core.config import settings
from core.constants import EMAIL_CODE_TTL_MINUTES, MAX_VERIFICATION_ATTEMPTS

logger = logging.getLogger(__name__)

EMAIL_CODE_LENGTH = 4  # Длина кода подтверждения


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
    logger.info(f"[code_service.hash_code] Исходный код: '{code}' (тип: {type(code).__name__}, длина: {len(code) if code else 0}), нормализованный: '{normalized_code}' (длина: {len(normalized_code)})")
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
    from core.logging_utils import mask_sensitive_string
    normalized_code = re.sub(r'\s+', '', code.strip()) if code else ""
    # Безопасное логирование кода (маскируем чувствительные данные)
    masked_code = mask_sensitive_string(code, visible_chars=0) if code else "None"
    masked_normalized = mask_sensitive_string(normalized_code, visible_chars=0) if normalized_code else "None"
    logger.info(f"[code_service.verify_code] Исходный код: '{masked_code}' (тип: {type(code).__name__}, длина: {len(code) if code else 0}), нормализованный: '{masked_normalized}' (длина: {len(normalized_code)})")
    logger.info(f"[code_service.verify_code] Хэш из БД: '{code_hash[:16]}...' (длина: {len(code_hash) if code_hash else 0})")
    
    if not normalized_code or not code_hash:
        logger.warning(f"[code_service.verify_code] Пустой код или хэш: normalized_code={bool(normalized_code)}, code_hash={bool(code_hash)}")
        return False
    
    computed_hash = hash_code(normalized_code)
    logger.info(f"[code_service.verify_code] Вычисленный хэш: '{computed_hash}' (длина: {len(computed_hash)})")
    logger.info(f"[code_service.verify_code] Хэш из БД: '{code_hash}' (длина: {len(code_hash)})")
    
    result = computed_hash == code_hash
    logger.info(f"[code_service.verify_code] Результат сравнения: {result} (computed_hash == code_hash)")
    
    if not result:
        # Безопасное логирование ошибки (маскируем чувствительные данные)
        masked_code = mask_sensitive_string(code, visible_chars=0) if code else "None"
        masked_normalized = mask_sensitive_string(normalized_code, visible_chars=0) if normalized_code else "None"
        logger.error(f"[code_service.verify_code] ❌ ХЭШИ НЕ СОВПАЛИ!")
        logger.error(f"[code_service.verify_code]   Введенный код (исходный): '{masked_code}'")
        logger.error(f"[code_service.verify_code]   Введенный код (нормализованный): '{masked_normalized}'")
        logger.error(f"[code_service.verify_code]   Вычисленный хэш: '{computed_hash[:16]}...' (полный хэш скрыт)")
        logger.error(f"[code_service.verify_code]   Хэш из БД: '{code_hash[:16]}...' (полный хэш скрыт)")
        logger.error(f"[code_service.verify_code]   Первые 16 символов вычисленного хэша: '{computed_hash[:16]}'")
        logger.error(f"[code_service.verify_code]   Первые 16 символов хэша из БД: '{code_hash[:16]}'")
    
    return result


def create_auth_code(
    email: str,
    code_hash: str,
    expires_at: datetime,
    db: Session,
    ip_address: Optional[str] = None
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
        db.commit()
        db.refresh(auth_code)
        
        logger.info(f"[code_service] Создан код подтверждения для {normalized_email}, id: {auth_code.id}, expires_at: {expires_at}")
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
            logger.info(f"[code_service] Код найден для {normalized_email}, id: {auth_code.id}, expires_at: {auth_code.expires_at}, attempts: {auth_code.attempts_count}, code_hash: {auth_code.code_hash[:16]}...")
        else:
            logger.warning(f"[code_service] Код не найден или истек для {normalized_email}, now: {now}")
        
        return auth_code
        
    except Exception as e:
        logger.error(f"[code_service] Ошибка при получении кода для {email}: {e}", exc_info=True)
        return None


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


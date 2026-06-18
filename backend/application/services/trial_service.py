"""
Сервис для управления триальными подписками.
Триал предоставляется новым пользователям на 24 часа (86400 секунд).
"""
import logging
from datetime import datetime, timedelta
from typing import Optional, Tuple
from sqlalchemy.orm import Session
from sqlalchemy import func, and_

from domain.models.user import User
from domain.models.subscription import Subscription

logger = logging.getLogger(__name__)

TRIAL_DURATION_SECONDS = 24 * 60 * 60  # 24 часа


def create_trial(user_id: int, seconds: int = TRIAL_DURATION_SECONDS, db: Optional[Session] = None) -> bool:
    """
    Создает триал для пользователя.
    
    Args:
        user_id: ID пользователя
        seconds: Длительность триала в секундах (по умолчанию 86400 = 24 часа)
        db: Сессия базы данных
    
    Returns:
        True если триал успешно создан, False в случае ошибки
    """
    if not db:
        logger.error("Не предоставлена сессия базы данных для create_trial")
        return False
    
    try:
        user = db.query(User).filter(User.id == user_id).first()
        if not user:
            logger.error(f"Пользователь {user_id} не найден")
            return False
        
        # Если триал уже активен, не создаем новый
        if user.trial_active:
            logger.info(f"У пользователя {user_id} уже есть активный триал")
            return True
        
        # Создаем триал
        now = datetime.utcnow()
        user.trial_active = True
        user.trial_seconds_left = seconds
        user.trial_started_at = now
        
        db.commit()
        logger.info(f"Создан триал для пользователя {user_id} ({seconds} секунд)")
        return True
        
    except Exception as e:
        logger.error(f"Ошибка при создании триала для пользователя {user_id}: {e}")
        db.rollback()
        return False


def get_trial_seconds_left(user_id: int, db: Session) -> int:
    """
    Получает оставшееся время триала в секундах.
    Если триал истек, обновляет статус пользователя.
    
    Args:
        user_id: ID пользователя
        db: Сессия базы данных
    
    Returns:
        Количество секунд, оставшихся до окончания триала (0 если триал неактивен или истек)
    """
    try:
        user = db.query(User).filter(User.id == user_id).first()
        if not user:
            return 0
        
        if not user.trial_active:
            return 0

        if user.trial_started_at:
            duration = max(0, user.trial_seconds_left or 0)
            elapsed = int((datetime.utcnow() - user.trial_started_at).total_seconds())
            remaining = max(0, duration - elapsed)
            
            if remaining <= 0:
                if user.trial_active:
                    deactivate_trial(user_id, db)
                return 0
            
            return remaining

        return user.trial_seconds_left
        
    except Exception as e:
        logger.error(f"Ошибка при получении оставшегося времени триала для пользователя {user_id}: {e}")
        return 0


def is_trial_active(user_id: int, db: Session) -> bool:
    """
    Проверяет, активен ли триал у пользователя.
    
    Args:
        user_id: ID пользователя
        db: Сессия базы данных
    
    Returns:
        True если триал активен, False иначе
    """
    try:
        user = db.query(User).filter(User.id == user_id).first()
        if not user:
            return False
        
        if not user.trial_active:
            return False
        
        # Проверяем, не истек ли триал
        seconds_left = get_trial_seconds_left(user_id, db)
        return seconds_left > 0
        
    except Exception as e:
        logger.error(f"Ошибка при проверке активности триала для пользователя {user_id}: {e}")
        return False


def deactivate_trial(user_id: int, db: Session, notify_user: bool = True) -> bool:
    """
    Деактивирует триал пользователя.
    
    Args:
        user_id: ID пользователя
        db: Сессия базы данных
    
    Returns:
        True если триал успешно деактивирован, False в случае ошибки
    """
    try:
        user = db.query(User).filter(User.id == user_id).first()
        if not user:
            logger.error(f"Пользователь {user_id} не найден")
            return False
        
        if not user.trial_active:
            return True  # Уже деактивирован
        
        user.trial_active = False
        user.trial_seconds_left = 0
        # trial_started_at оставляем для истории

        notification_ok = False
        if notify_user:
            try:
                from services.notification_service import notify_trial_ended
                notification_ok = bool(notify_trial_ended(user))
            except Exception as e:
                logger.exception(
                    "Ошибка отправки уведомления окончания триала для пользователя %s: %s",
                    user_id,
                    e,
                )
        setattr(user, "_trial_end_notification_ok", notification_ok)

        try:
            from core.cache import invalidate_user_cache
            invalidate_user_cache(user_id)
        except Exception as e:
            logger.warning(
                "Ошибка инвалидации cache при окончании триала user_id=%s: %s",
                user_id,
                e,
            )
        
        db.commit()
        logger.info(f"Триал деактивирован для пользователя {user_id}")
        return True
        
    except Exception as e:
        logger.error(f"Ошибка при деактивации триала для пользователя {user_id}: {e}")
        db.rollback()
        return False


def has_active_subscription(user_id: int, db: Session) -> bool:
    """
    Проверяет, есть ли у пользователя активная платная подписка.
    
    Args:
        user_id: ID пользователя
        db: Сессия базы данных
    
    Returns:
        True если есть активная подписка, False иначе
    """
    try:
        active_subscription = db.query(Subscription).filter(
            and_(
                Subscription.user_id == user_id,
                Subscription.status == "active",
                Subscription.end_date > datetime.utcnow()
            )
        ).first()
        
        return active_subscription is not None
        
    except Exception as e:
        logger.error(f"Ошибка при проверке активной подписки для пользователя {user_id}: {e}")
        return False


def get_user_access_info(user_id: int, db: Session) -> Tuple[int, bool]:
    """
    Получает информацию о доступе пользователя.
    
    Args:
        user_id: ID пользователя
        db: Сессия базы данных
    
    Returns:
        Кортеж (trial_seconds_left, has_active_subscription):
        - trial_seconds_left: оставшееся время триала в секундах (0 если нет)
        - has_active_subscription: есть ли активная платная подписка
    """
    trial_seconds = get_trial_seconds_left(user_id, db)
    has_subscription = has_active_subscription(user_id, db)
    
    return (trial_seconds, has_subscription)






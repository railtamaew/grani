from sqlalchemy.orm import Session
from datetime import datetime, timedelta
from typing import Optional, Tuple
from fastapi import HTTPException, status, Request
import redis
import logging

from core.config import settings
from domain.models.user import User, UserRole
from domain.models.admin_login_log import AdminLoginLog
from application.services.auth_service import AuthService

logger = logging.getLogger(__name__)

# Инициализация Redis клиента
try:
    redis_client = redis.from_url(settings.redis_url, decode_responses=True)
except Exception as e:
    logger.warning(f"Redis недоступен: {e}. Rate limiting будет работать без Redis.")
    redis_client = None


class AdminAuthService:
    """Сервис для аутентификации администраторов с rate limiting"""
    
    def __init__(self, db: Session):
        self.db = db
        self.redis = redis_client
    
    def login(self, email: str, password: str, ip_address: str = None, user_agent: str = None) -> Tuple[User, str]:
        """
        Аутентификация администратора с проверкой rate limiting
        
        Returns:
            Tuple[User, str]: Пользователь и JWT токен
        
        Raises:
            HTTPException: При неверных учетных данных или блокировке
        """
        email_lower = email.lower().strip()
        
        # Проверка блокировки аккаунта
        blocked_until = self.get_blocked_until(email_lower)
        if blocked_until:
            time_left = (blocked_until - datetime.utcnow()).total_seconds()
            minutes_left = int(time_left / 60) + 1
            self._log_login_attempt(email_lower, ip_address, user_agent, False, "account_locked")
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail=f"Аккаунт заблокирован. Попробуйте через {minutes_left} минут."
            )
        
        # Поиск пользователя
        user = self.db.query(User).filter(User.email == email_lower).first()
        
        if not user or not user.password_hash:
            self._log_login_attempt(email_lower, ip_address, user_agent, False, "user_not_found")
            self._increment_failed_attempts(email_lower, ip_address)
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Неверный email или пароль"
            )
        
        # Проверка, что пользователь является админом
        if not user.role or user.role not in [UserRole.OWNER, UserRole.ADMIN, UserRole.SUPPORT, UserRole.READ_ONLY]:
            self._log_login_attempt(email_lower, ip_address, user_agent, False, "not_admin")
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Доступ запрещен. Только администраторы могут войти в админ-панель."
            )
        
        # Проверка активности пользователя
        if not user.is_active:
            self._log_login_attempt(email_lower, ip_address, user_agent, False, "account_disabled")
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Аккаунт деактивирован"
            )
        
        # Проверка пароля
        if not AuthService.verify_password(password, user.password_hash):
            self._log_login_attempt(email_lower, ip_address, user_agent, False, "wrong_password")
            self._increment_failed_attempts(email_lower, ip_address)
            
            # Проверка после неудачной попытки
            blocked_until = self.get_blocked_until(email_lower)
            if blocked_until:
                time_left = (blocked_until - datetime.utcnow()).total_seconds()
                minutes_left = int(time_left / 60) + 1
                raise HTTPException(
                    status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                    detail=f"Слишком много неудачных попыток. Аккаунт заблокирован на {minutes_left} минут."
                )
            
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Неверный email или пароль"
            )
        
        # Успешный вход
        user.last_login_at = datetime.utcnow()
        user.last_seen_at = datetime.utcnow()
        self.db.commit()
        
        # Сброс счетчика неудачных попыток
        self._reset_failed_attempts(email_lower, ip_address)
        
        # Логирование успешного входа
        self._log_login_attempt(email_lower, ip_address, user_agent, True, None)
        
        # Создание токена
        token = AuthService.create_access_token(user.id)
        
        return user, token
    
    def get_blocked_until(self, email: str, ip_address: str = None) -> Optional[datetime]:
        """
        Проверяет, заблокирован ли аккаунт или IP
        
        Returns:
            Optional[datetime]: Время до которого заблокирован, или None
        """
        email_lower = email.lower().strip()
        
        # Проверка блокировки по email
        if self.redis:
            blocked_key_email = f"admin:blocked:email:{email_lower}"
            blocked_until_str = self.redis.get(blocked_key_email)
            if blocked_until_str:
                try:
                    return datetime.fromisoformat(blocked_until_str)
                except:
                    pass
        
        # Проверка блокировки по IP
        if ip_address:
            if self.redis:
                blocked_key_ip = f"admin:blocked:ip:{ip_address}"
                blocked_until_str = self.redis.get(blocked_key_ip)
                if blocked_until_str:
                    try:
                        return datetime.fromisoformat(blocked_until_str)
                    except:
                        pass
        
        # Проверка в БД (fallback, если Redis недоступен)
        user_id = self._get_user_id_by_email(email_lower)
        if user_id:
            recent_failures = self.db.query(AdminLoginLog).filter(
                AdminLoginLog.user_id == user_id,
                AdminLoginLog.success == False,
                AdminLoginLog.created_at >= datetime.utcnow() - timedelta(minutes=settings.admin_lockout_duration_minutes)
            ).count()
            
            if recent_failures >= settings.admin_max_login_attempts:
                # Блокировка на lockout_duration
                return datetime.utcnow() + timedelta(minutes=settings.admin_lockout_duration_minutes)
        
        return None
    
    def _increment_failed_attempts(self, email: str, ip_address: str = None):
        """Увеличивает счетчик неудачных попыток"""
        email_lower = email.lower().strip()
        
        if self.redis:
            # Счетчик по email
            attempts_key_email = f"admin:attempts:email:{email_lower}"
            attempts = self.redis.incr(attempts_key_email)
            self.redis.expire(attempts_key_email, settings.admin_lockout_duration_minutes * 60)
            
            # Счетчик по IP
            if ip_address:
                attempts_key_ip = f"admin:attempts:ip:{ip_address}"
                attempts_ip = self.redis.incr(attempts_key_ip)
                self.redis.expire(attempts_key_ip, settings.admin_lockout_duration_minutes * 60)
            
            # Если превышен лимит, устанавливаем блокировку
            if attempts >= settings.admin_max_login_attempts:
                blocked_until = datetime.utcnow() + timedelta(minutes=settings.admin_lockout_duration_minutes)
                blocked_key_email = f"admin:blocked:email:{email_lower}"
                self.redis.setex(blocked_key_email, settings.admin_lockout_duration_minutes * 60, blocked_until.isoformat())
                
                if ip_address:
                    blocked_key_ip = f"admin:blocked:ip:{ip_address}"
                    self.redis.setex(blocked_key_ip, settings.admin_lockout_duration_minutes * 60, blocked_until.isoformat())
    
    def _reset_failed_attempts(self, email: str, ip_address: str = None):
        """Сбрасывает счетчик неудачных попыток"""
        email_lower = email.lower().strip()
        
        if self.redis:
            attempts_key_email = f"admin:attempts:email:{email_lower}"
            self.redis.delete(attempts_key_email)
            
            blocked_key_email = f"admin:blocked:email:{email_lower}"
            self.redis.delete(blocked_key_email)
            
            if ip_address:
                attempts_key_ip = f"admin:attempts:ip:{ip_address}"
                self.redis.delete(attempts_key_ip)
                
                blocked_key_ip = f"admin:blocked:ip:{ip_address}"
                self.redis.delete(blocked_key_ip)
    
    def _log_login_attempt(self, email: str, ip_address: str, user_agent: str, success: bool, failure_reason: str = None):
        """Логирует попытку входа"""
        user = self.db.query(User).filter(User.email == email.lower().strip()).first()
        if not user:
            return
        
        log_entry = AdminLoginLog(
            user_id=user.id,
            ip_address=ip_address,
            user_agent=user_agent,
            success=success,
            failure_reason=failure_reason
        )
        self.db.add(log_entry)
        self.db.commit()
    
    def _get_user_id_by_email(self, email: str) -> Optional[int]:
        """Получает ID пользователя по email"""
        user = self.db.query(User).filter(User.email == email.lower().strip()).first()
        return user.id if user else None
    
    @staticmethod
    def check_rate_limit(email: str, ip_address: str = None) -> bool:
        """
        Проверяет rate limit для логина
        
        Returns:
            bool: True если можно продолжить, False если превышен лимит
        """
        if not redis_client:
            return True  # Если Redis недоступен, пропускаем проверку
        
        email_lower = email.lower().strip()
        
        # Проверка блокировки по email
        blocked_key_email = f"admin:blocked:email:{email_lower}"
        if redis_client.exists(blocked_key_email):
            return False
        
        # Проверка блокировки по IP
        if ip_address:
            blocked_key_ip = f"admin:blocked:ip:{ip_address}"
            if redis_client.exists(blocked_key_ip):
                return False
        
        return True


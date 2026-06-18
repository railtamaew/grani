from sqlalchemy.orm import Session
from datetime import datetime, timedelta
import jwt
import re
from passlib.context import CryptContext
from fastapi import HTTPException, status
from typing import Optional, Union

from core.config import settings
from models.user import User
from schemas.user import UserResponse

# Настройка хеширования паролей
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

class AuthService:
    PASSWORD_BLACKLIST = {
        "123456",
        "12345678",
        "qwerty",
        "password",
        "granivpn",
        "granilink",
        "11111111",
    }
    
    def __init__(self, db: Session):
        self.db = db
    
    @staticmethod
    def hash_password(password: str) -> str:
        """Хеширование пароля"""
        return pwd_context.hash(password)
    
    @staticmethod
    def verify_password(plain_password: str, hashed_password: str) -> bool:
        """Проверка пароля"""
        if not hashed_password:
            return False
        return pwd_context.verify(plain_password, hashed_password)
    
    @staticmethod
    def create_access_token(user_id: int) -> str:
        """Создание JWT access token (1 час, refresh token для продления)"""
        expire = datetime.utcnow() + timedelta(minutes=settings.access_token_expire_minutes)
        to_encode = {"exp": expire, "sub": str(user_id), "type": "access"}
        encoded_jwt = jwt.encode(to_encode, settings.secret_key, algorithm=settings.algorithm)
        return encoded_jwt
    
    @staticmethod
    def create_refresh_token(user_id: int) -> str:
        """Создание JWT refresh token (90 дней)"""
        expire = datetime.utcnow() + timedelta(days=settings.refresh_token_expire_days)
        to_encode = {"exp": expire, "sub": str(user_id), "type": "refresh"}
        encoded_jwt = jwt.encode(to_encode, settings.secret_key, algorithm=settings.algorithm)
        return encoded_jwt
    
    @staticmethod
    def verify_token(token: str, token_type: str = "access") -> Optional[int]:
        """Проверка JWT токена с проверкой типа и поддержкой ротации ключей"""
        # Поддержка ротации SECRET_KEY: пробуем новый ключ, затем старый
        secret_keys = getattr(settings, 'jwt_secret_keys', [settings.secret_key])
        
        for secret_key in secret_keys:
            try:
                payload = jwt.decode(token, secret_key, algorithms=[settings.algorithm])
                
                # Проверяем тип токена
                if payload.get("type") != token_type:
                    continue  # Пробуем следующий ключ
                    
                user_id = payload.get("sub")
                if user_id is None:
                    continue
                return int(user_id)
            except jwt.ExpiredSignatureError:
                return None  # Токен истек, не пробуем другие ключи
            except jwt.InvalidTokenError:
                continue  # Пробуем следующий ключ
            except Exception:
                continue  # Пробуем следующий ключ
        
        return None  # Не удалось проверить ни с одним ключом
    
    @staticmethod
    def refresh_access_token(refresh_token: str) -> Optional[str]:
        """Обновление access token через refresh token"""
        user_id = AuthService.verify_token(refresh_token, token_type="refresh")
        if user_id is None:
            return None
        # Создаем новый access token
        return AuthService.create_access_token(user_id)
    
    @staticmethod
    def get_current_user(token: str, db: Session) -> Union[User, UserResponse]:
        """Получение текущего пользователя по токену"""
        import logging
        logger = logging.getLogger(__name__)
        # Безопасное логирование токена (показываем только длину)
        logger.debug(f"get_current_user: token length={len(token) if token else 0}, first 4 chars={token[:4] if token and len(token) >= 4 else 'None'}...")
        
        user_id = AuthService.verify_token(token)
        logger.debug(f"get_current_user: verified user_id={user_id}")
        
        if user_id is None:
            logger.warning(f"get_current_user: token verification failed")
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Неверный токен"
            )
        
        # Используем raw SQL для получения данных пользователя
        # Это позволяет избежать проблем с инициализацией relationships
        from sqlalchemy import text
        
        result = db.execute(
            text(
                "SELECT id, email, is_active, is_verified, auth_provider, created_at, "
                "updated_at, trial_active, preferred_language "
                "FROM users WHERE id = :user_id"
            ),
            {"user_id": user_id}
        )
        row = result.fetchone()
        
        if row is None:
            logger.warning(f"get_current_user: user not found for id={user_id}")
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Пользователь не найден"
            )
        
        if not row.is_active:
            logger.warning(f"get_current_user: user {user_id} is not active")
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Пользователь заблокирован"
            )
        
        # Создаем Pydantic модель для избежания проблем с SQLAlchemy relationships
        user = UserResponse(
            id=row.id,
            email=row.email,
            is_active=row.is_active,
            is_verified=row.is_verified,
            auth_provider=row.auth_provider,
            created_at=row.created_at,
            updated_at=row.updated_at,
            trial_active=getattr(row, "trial_active", False),
            preferred_language=(getattr(row, "preferred_language", None) or "en"),
        )
        
        logger.debug(f"get_current_user: user {user.email} (id={user.id}) retrieved successfully")
        return user
    
    def create_user(self, email: str, password: str) -> User:
        """Создание нового пользователя"""
        # Проверяем, существует ли пользователь
        existing_user = self.db.query(User).filter(User.email == email).first()
        if existing_user:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Пользователь с таким email уже существует"
            )
        
        # Хешируем пароль
        hashed_password = self.hash_password(password)
        
        # Создаем пользователя
        user = User(
            email=email,
            password_hash=hashed_password,
            is_verified=True,
            auth_provider="email",
        )
        
        self.db.add(user)
        self.db.commit()
        self.db.refresh(user)
        
        return user
    
    def authenticate_user(self, email: str, password: str) -> Optional[User]:
        """Аутентификация пользователя"""
        user = self.db.query(User).filter(User.email == email).first()
        if not user:
            return None
        
        if user.auth_provider and user.auth_provider != "email":
            # Аккаунт создан через другой провайдер
            return None
        
        if not self.verify_password(password, user.password_hash):
            return None
        
        if not user.is_verified:
            return None
        
        return user
    
    def change_password(self, user_id: int, old_password: str, new_password: str) -> bool:
        """Смена пароля"""
        user = self.db.query(User).filter(User.id == user_id).first()
        if not user:
            return False
        
        if not self.verify_password(old_password, user.password_hash):
            return False
        
        user.password_hash = self.hash_password(new_password)
        self.db.commit()
        
        return True
    
    def reset_password(self, email: str) -> bool:
        """Сброс пароля"""
        user = self.db.query(User).filter(User.email == email).first()
        if not user:
            return False
        
        # Генерируем новый пароль
        import random
        import string
        new_password = ''.join(random.choices(string.ascii_letters + string.digits, k=12))
        
        user.password_hash = self.hash_password(new_password)
        self.db.commit()
        
        # TODO: Отправить новый пароль на email
        
        return True
    
    @staticmethod
    def validate_password_strength(password: str, email: str):
        """Проверка сложности пароля"""
        if not password or len(password) < 8 or len(password) > 64:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Пароль должен содержать от 8 до 64 символов"
            )
        
        if not re.search(r"[a-z]", password):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Пароль должен содержать хотя бы одну строчную букву"
            )
        if not re.search(r"[A-Z]", password):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Пароль должен содержать хотя бы одну заглавную букву"
            )
        if not re.search(r"[0-9]", password):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Пароль должен содержать хотя бы одну цифру"
            )
        
        password_lower = password.lower()
        local_part = email.split("@")[0].lower()
        if local_part and local_part in password_lower:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Пароль не должен содержать ваш email"
            )
        
        if password_lower in AuthService.PASSWORD_BLACKLIST:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Выберите более сложный пароль"
            )










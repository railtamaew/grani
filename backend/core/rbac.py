from functools import wraps
from typing import List, Callable
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.orm import Session

from core.database import get_db
from models.user import User, UserRole
from services.auth_service import AuthService

security = HTTPBearer()

# Алиас для совместимости с существующим кодом
require_admin = None  # Будет установлен ниже

def get_current_admin_user(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db)
) -> User:
    """
    Получает текущего администратора по JWT токену
    
    Raises:
        HTTPException: Если токен невалиден или пользователь не админ
    """
    token = credentials.credentials
    user_id = AuthService.verify_token(token)
    
    if not user_id:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Неверный токен"
        )
    
    user = db.query(User).filter(User.id == user_id).first()
    
    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Пользователь не найден"
        )
    
    if not user.is_active:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Аккаунт деактивирован"
        )
    
    # Проверяем, что пользователь является админом
    if not user.role or user.role not in [UserRole.OWNER, UserRole.ADMIN, UserRole.SUPPORT, UserRole.READ_ONLY]:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Доступ запрещен. Только администраторы могут использовать админ-панель."
        )
    
    return user

# Устанавливаем алиас для совместимости
require_admin = get_current_admin_user

def require_role(roles: List[UserRole]):
    """
    Декоратор для проверки роли пользователя
    
    Args:
        roles: Список разрешенных ролей
    
    Usage:
        @router.get("/admin/users")
        async def get_users(user: User = Depends(require_role([UserRole.ADMIN, UserRole.OWNER]))):
            ...
    """
    def role_checker(user: User = Depends(get_current_admin_user)) -> User:
        if user.role not in roles:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Недостаточно прав. Требуются роли: {', '.join([r.value for r in roles])}"
            )
        return user
    return role_checker

def require_owner(user: User = Depends(get_current_admin_user)) -> User:
    """
    Зависимость для проверки, что пользователь является Owner
    
    Usage:
        @router.get("/admin/settings")
        async def get_settings(user: User = Depends(require_owner)):
            ...
    """
    if user.role != UserRole.OWNER:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Только Owner может выполнять это действие"
        )
    return user

def require_admin_or_owner(user: User = Depends(get_current_admin_user)) -> User:
    """
    Зависимость для проверки, что пользователь является Admin или Owner
    
    Usage:
        @router.delete("/admin/users/{user_id}")
        async def delete_user(user_id: int, user: User = Depends(require_admin_or_owner)):
            ...
    """
    if user.role not in [UserRole.ADMIN, UserRole.OWNER]:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Только Admin или Owner может выполнять это действие"
        )
    return user

def require_support_or_above(user: User = Depends(get_current_admin_user)) -> User:
    """
    Зависимость для проверки, что пользователь имеет роль Support или выше
    (Support, Admin, Owner)
    
    Usage:
        @router.patch("/admin/incidents/{incident_id}")
        async def update_incident(incident_id: int, user: User = Depends(require_support_or_above)):
            ...
    """
    if user.role not in [UserRole.SUPPORT, UserRole.ADMIN, UserRole.OWNER]:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Только Support, Admin или Owner может выполнять это действие"
        )
    return user


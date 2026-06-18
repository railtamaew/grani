from fastapi import APIRouter, Depends, HTTPException, status, Request
from sqlalchemy.orm import Session
from pydantic import BaseModel, EmailStr
from typing import Optional

from core.database import get_db
from core.rbac import get_current_admin_user
from models.user import User
from services.admin_auth_service import AdminAuthService
from services.auth_service import AuthService

router = APIRouter()

class LoginRequest(BaseModel):
    email: EmailStr
    password: str

class LoginResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user: dict

class AdminUserResponse(BaseModel):
    id: int
    email: str
    role: str
    is_active: bool
    created_at: str

@router.post("/login", response_model=LoginResponse)
async def login(
    request: LoginRequest,
    http_request: Request,
    db: Session = Depends(get_db)
):
    """
    Вход в админ-панель с rate limiting
    """
    # Получаем IP и user-agent
    ip_address = None
    user_agent = None
    
    forwarded_for = http_request.headers.get("X-Forwarded-For")
    if forwarded_for:
        ip_address = forwarded_for.split(",")[0].strip()
    else:
        ip_address = http_request.client.host if http_request.client else None
    
    user_agent = http_request.headers.get("User-Agent")
    
    # Аутентификация
    auth_service = AdminAuthService(db)
    try:
        user, token = auth_service.login(
            email=request.email,
            password=request.password,
            ip_address=ip_address,
            user_agent=user_agent
        )
    except HTTPException as e:
        raise e
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Ошибка входа: {str(e)}"
        )
    
    return LoginResponse(
        access_token=token,
        token_type="bearer",
        user={
            "id": user.id,
            "email": user.email,
            "role": user.role.value if user.role else None,
            "is_active": user.is_active
        }
    )

@router.post("/logout")
async def logout(
    user: User = Depends(get_current_admin_user)
):
    """
    Выход из админ-панели
    (В текущей реализации JWT токены не хранятся на сервере,
     поэтому просто возвращаем успех. Можно добавить blacklist токенов)
    """
    return {"message": "Выход выполнен успешно"}

@router.get("/me", response_model=AdminUserResponse)
async def get_current_admin(
    user: User = Depends(get_current_admin_user),
    db: Session = Depends(get_db)
):
    """
    Получение информации о текущем администраторе
    """
    return AdminUserResponse(
        id=user.id,
        email=user.email,
        role=user.role.value if user.role else None,
        is_active=user.is_active,
        created_at=user.created_at.isoformat() if user.created_at else None
    )


class ChangePasswordRequest(BaseModel):
    current_password: str
    new_password: str


@router.post("/change-password")
async def change_password(
    payload: ChangePasswordRequest,
    user: User = Depends(get_current_admin_user),
    db: Session = Depends(get_db)
):
    """
    Смена пароля текущего администратора.
    Недоступно для аккаунтов, входящих только через Google (без пароля).
    """
    if not getattr(user, "password_hash", None):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Смена пароля недоступна для аккаунтов, входящих через Google. Установите пароль в настройках профиля."
        )
    if len(payload.new_password) < 8 or len(payload.new_password) > 64:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Пароль должен содержать от 8 до 64 символов"
        )
    auth_service = AuthService(db)
    if not auth_service.verify_password(payload.current_password, user.password_hash):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Неверный текущий пароль"
        )
    user.password_hash = AuthService.hash_password(payload.new_password)
    db.commit()
    return {"message": "Пароль успешно изменён"}




"""Pydantic схемы для пользователей"""
from pydantic import BaseModel
from datetime import datetime
from typing import Optional

class UserResponse(BaseModel):
    """Модель пользователя для API ответов"""
    id: int
    email: str
    is_active: bool
    is_verified: bool
    auth_provider: str
    created_at: datetime
    updated_at: datetime
    trial_active: bool = False
    preferred_language: str = "en"
    
    class Config:
        from_attributes = True







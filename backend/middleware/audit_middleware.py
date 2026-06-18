from functools import wraps
from typing import Callable, Any
from sqlalchemy.orm import Session
from datetime import datetime
from fastapi import Request, Depends
import json

from core.database import get_db
from models.audit_log import AuditLog
from models.user import User
from services.auth_service import AuthService

def audit_log(action: str, entity_type: str, get_entity_id: Callable = None):
    """
    Декоратор для автоматического логирования действий админов
    
    Args:
        action: Действие (create, update, delete, enable, disable, etc.)
        entity_type: Тип сущности (user, server, protocol, etc.)
        get_entity_id: Функция для получения ID сущности из response (по умолчанию берет из path params)
    """
    def decorator(func: Callable):
        @wraps(func)
        async def wrapper(*args, **kwargs):
            # Получаем request из kwargs (FastAPI автоматически инжектирует)
            request: Request = kwargs.get('request') or (args[0] if args and isinstance(args[0], Request) else None)
            db: Session = kwargs.get('db')
            
            # Если db не в kwargs, пытаемся получить из Depends
            if not db:
                for arg in args:
                    if isinstance(arg, Session):
                        db = arg
                        break
            
            if not db:
                # Если не удалось получить db, выполняем функцию без аудита
                return await func(*args, **kwargs)
            
            # Получаем текущего пользователя из токена
            admin_user = None
            if request:
                auth_header = request.headers.get("Authorization")
                if auth_header and auth_header.startswith("Bearer "):
                    token = auth_header.split(" ")[1]
                    user_id = AuthService.verify_token(token)
                    if user_id:
                        admin_user = db.query(User).filter(User.id == user_id).first()
            
            # Получаем IP и user-agent
            ip_address = None
            user_agent = None
            if request:
                # IP адрес
                forwarded_for = request.headers.get("X-Forwarded-For")
                if forwarded_for:
                    ip_address = forwarded_for.split(",")[0].strip()
                else:
                    ip_address = request.client.host if request.client else None
                
                # User-Agent
                user_agent = request.headers.get("User-Agent")
            
            # Выполняем функцию
            try:
                result = await func(*args, **kwargs)
                
                # Определяем entity_id
                entity_id = None
                if get_entity_id:
                    entity_id = get_entity_id(result, *args, **kwargs)
                else:
                    # Пытаемся получить из path params (например, user_id, server_id)
                    if request:
                        entity_type_lower = entity_type.lower()
                        # Проверяем path_params
                        for key in request.path_params:
                            if entity_type_lower in key.lower():
                                entity_id = request.path_params.get(key)
                                break
                        
                        # Если не нашли, пытаемся получить из kwargs
                        if not entity_id:
                            for key in kwargs:
                                if entity_type_lower in key.lower() and isinstance(kwargs[key], int):
                                    entity_id = kwargs[key]
                                    break
                
                # Старое значение (для update/delete) - сложно получить без дополнительных запросов
                old_value = None
                new_value = None
                
                # Новое значение (для create/update)
                if isinstance(result, dict):
                    new_value = result
                elif hasattr(result, 'dict'):
                    new_value = result.dict()
                elif hasattr(result, '__dict__'):
                    new_value = {k: str(v) for k, v in result.__dict__.items() if not k.startswith('_')}
                
                # Создаем запись в audit log
                if admin_user:
                    audit_entry = AuditLog(
                        admin_user_id=admin_user.id,
                        action=action,
                        entity_type=entity_type,
                        entity_id=entity_id,
                        old_value=old_value,
                        new_value=new_value,
                        ip_address=ip_address,
                        user_agent=user_agent
                    )
                    db.add(audit_entry)
                    db.commit()
                
                return result
            except Exception as e:
                # В случае ошибки также логируем
                if admin_user and db:
                    try:
                        audit_entry = AuditLog(
                            admin_user_id=admin_user.id,
                            action=f"{action}_error",
                            entity_type=entity_type,
                            entity_id=entity_id,
                            old_value=None,
                            new_value={"error": str(e)},
                            ip_address=ip_address,
                            user_agent=user_agent
                        )
                        db.add(audit_entry)
                        db.commit()
                    except:
                        pass  # Не блокируем обработку ошибки из-за проблем с аудитом
                raise
        
        return wrapper
    return decorator


def create_audit_log(
    db: Session,
    admin_user: User,
    action: str,
    entity_type: str,
    entity_id: Any,
    old_value: dict = None,
    new_value: dict = None,
    ip_address: str = None,
    user_agent: str = None
):
    """
    Утилитная функция для создания записи в audit log вручную
    
    Используется когда нужен больший контроль над логированием
    """
    audit_entry = AuditLog(
        admin_user_id=admin_user.id,
        action=action,
        entity_type=entity_type,
        entity_id=entity_id,
        old_value=old_value,
        new_value=new_value,
        ip_address=ip_address,
        user_agent=user_agent
    )
    db.add(audit_entry)
    db.commit()




from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from datetime import datetime
from typing import Optional
from sqlalchemy import and_

from core.database import get_db
from core.rbac import require_owner
from models.user import User
from models.audit_log import AuditLog

router = APIRouter()

@router.get("/audit-log")
async def get_audit_log(
    admin_user_id: Optional[int] = None,
    entity_type: Optional[str] = None,
    entity_id: Optional[int] = None,
    start_date: Optional[datetime] = None,
    end_date: Optional[datetime] = None,
    skip: int = 0,
    limit: int = 100,
    admin_user: User = Depends(require_owner),
    db: Session = Depends(get_db)
):
    """Список действий админов (audit log)"""
    query = db.query(AuditLog)
    
    if admin_user_id:
        query = query.filter(AuditLog.admin_user_id == admin_user_id)
    
    if entity_type:
        query = query.filter(AuditLog.entity_type == entity_type)
    
    if entity_id:
        query = query.filter(AuditLog.entity_id == entity_id)
    
    if start_date:
        query = query.filter(AuditLog.created_at >= start_date)
    
    if end_date:
        query = query.filter(AuditLog.created_at <= end_date)
    
    logs = query.order_by(AuditLog.created_at.desc()).offset(skip).limit(limit).all()
    
    result = []
    for log in logs:
        # Получаем email админа
        admin_email = None
        admin = db.query(User).filter(User.id == log.admin_user_id).first()
        if admin:
            admin_email = admin.email
        
        result.append({
            "id": log.id,
            "admin_user_id": log.admin_user_id,
            "admin_email": admin_email,
            "action": log.action,
            "entity_type": log.entity_type,
            "entity_id": log.entity_id,
            "old_value": log.old_value,
            "new_value": log.new_value,
            "ip_address": log.ip_address,
            "user_agent": log.user_agent,
            "created_at": log.created_at.isoformat() if log.created_at else None
        })
    
    return result




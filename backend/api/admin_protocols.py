from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from datetime import datetime, timedelta
from typing import List, Optional
from pydantic import BaseModel
from sqlalchemy import func

from core.database import get_db
from core.rbac import require_admin_or_owner, get_current_admin_user as require_admin
from models.user import User
from models.protocol import Protocol
from models.server import Server
from models.telemetry import TelemetryEvent

router = APIRouter()

class ProtocolCreate(BaseModel):
    name: str
    code: str
    status: str = "enabled"
    app_supported: Optional[dict] = None
    config_schema: Optional[dict] = None
    release_notes: Optional[str] = None

class ProtocolUpdate(BaseModel):
    name: Optional[str] = None
    status: Optional[str] = None
    app_supported: Optional[dict] = None
    config_schema: Optional[dict] = None
    release_notes: Optional[str] = None

@router.get("/protocols")
async def get_protocols(
    admin_user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Список протоколов"""
    protocols = db.query(Protocol).all()
    
    result = []
    for protocol in protocols:
        # Подсчет активных пользователей за последние 24 часа
        yesterday = datetime.utcnow() - timedelta(days=1)
        active_users_24h = db.query(func.count(func.distinct(TelemetryEvent.user_id))).filter(
            TelemetryEvent.protocol_code == protocol.code,
            TelemetryEvent.timestamp >= yesterday,
            TelemetryEvent.event_type == "connect_success"
        ).scalar() or 0
        
        result.append({
            "id": protocol.id,
            "name": protocol.name,
            "code": protocol.code,
            "status": protocol.status,
            "app_supported": protocol.app_supported or [],
            "config_schema": protocol.config_schema or {},
            "release_notes": protocol.release_notes,
            "active_users_24h": active_users_24h,
            "created_at": protocol.created_at.isoformat() if protocol.created_at else None,
            "updated_at": protocol.updated_at.isoformat() if protocol.updated_at else None
        })
    
    return result

@router.post("/protocols")
async def create_protocol(
    protocol_data: ProtocolCreate,
    admin_user: User = Depends(require_admin_or_owner),
    db: Session = Depends(get_db)
):
    """Создание протокола"""
    # Проверка на уникальность code
    existing = db.query(Protocol).filter(Protocol.code == protocol_data.code).first()
    if existing:
        raise HTTPException(status_code=400, detail="Протокол с таким code уже существует")
    
    protocol = Protocol(
        name=protocol_data.name,
        code=protocol_data.code,
        status=protocol_data.status,
        app_supported=protocol_data.app_supported,
        config_schema=protocol_data.config_schema,
        release_notes=protocol_data.release_notes
    )
    
    db.add(protocol)
    db.commit()
    db.refresh(protocol)
    
    return {"message": "Протокол создан", "protocol_id": protocol.id}

@router.patch("/protocols/{protocol_id}")
async def update_protocol(
    protocol_id: int,
    protocol_data: ProtocolUpdate,
    admin_user: User = Depends(require_admin_or_owner),
    db: Session = Depends(get_db)
):
    """Обновление протокола"""
    protocol = db.query(Protocol).filter(Protocol.id == protocol_id).first()
    if not protocol:
        raise HTTPException(status_code=404, detail="Протокол не найден")
    
    if protocol_data.name is not None:
        protocol.name = protocol_data.name
    if protocol_data.status is not None:
        protocol.status = protocol_data.status
    if protocol_data.app_supported is not None:
        protocol.app_supported = protocol_data.app_supported
    if protocol_data.config_schema is not None:
        protocol.config_schema = protocol_data.config_schema
    if protocol_data.release_notes is not None:
        protocol.release_notes = protocol_data.release_notes
    
    protocol.updated_at = datetime.utcnow()
    db.commit()
    
    return {"message": "Протокол обновлен"}

@router.post("/protocols/{protocol_id}/enable")
async def enable_protocol(
    protocol_id: int,
    admin_user: User = Depends(require_admin_or_owner),
    db: Session = Depends(get_db)
):
    """Включение протокола"""
    protocol = db.query(Protocol).filter(Protocol.id == protocol_id).first()
    if not protocol:
        raise HTTPException(status_code=404, detail="Протокол не найден")
    
    protocol.status = "enabled"
    protocol.updated_at = datetime.utcnow()
    db.commit()
    
    return {"message": "Протокол включен"}

@router.post("/protocols/{protocol_id}/disable")
async def disable_protocol(
    protocol_id: int,
    admin_user: User = Depends(require_admin_or_owner),
    db: Session = Depends(get_db)
):
    """Выключение протокола"""
    protocol = db.query(Protocol).filter(Protocol.id == protocol_id).first()
    if not protocol:
        raise HTTPException(status_code=404, detail="Протокол не найден")
    
    protocol.status = "disabled"
    protocol.updated_at = datetime.utcnow()
    db.commit()
    
    return {"message": "Протокол выключен"}

@router.get("/protocols/{protocol_id}/stats")
async def get_protocol_stats(
    protocol_id: int,
    days: int = 30,
    admin_user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Статистика по протоколу"""
    protocol = db.query(Protocol).filter(Protocol.id == protocol_id).first()
    if not protocol:
        raise HTTPException(status_code=404, detail="Протокол не найден")
    
    since = datetime.utcnow() - timedelta(days=days)
    
    # Активные пользователи
    active_users_24h = db.query(func.count(func.distinct(TelemetryEvent.user_id))).filter(
        TelemetryEvent.protocol_code == protocol.code,
        TelemetryEvent.timestamp >= datetime.utcnow() - timedelta(days=1),
        TelemetryEvent.event_type == "connect_success"
    ).scalar() or 0
    
    active_users_7d = db.query(func.count(func.distinct(TelemetryEvent.user_id))).filter(
        TelemetryEvent.protocol_code == protocol.code,
        TelemetryEvent.timestamp >= datetime.utcnow() - timedelta(days=7),
        TelemetryEvent.event_type == "connect_success"
    ).scalar() or 0
    
    active_users_30d = db.query(func.count(func.distinct(TelemetryEvent.user_id))).filter(
        TelemetryEvent.protocol_code == protocol.code,
        TelemetryEvent.timestamp >= datetime.utcnow() - timedelta(days=30),
        TelemetryEvent.event_type == "connect_success"
    ).scalar() or 0
    
    # Ошибки
    errors = db.query(TelemetryEvent).filter(
        TelemetryEvent.protocol_code == protocol.code,
        TelemetryEvent.timestamp >= since,
        TelemetryEvent.error_code.isnot(None)
    ).count()
    
    return {
        "protocol_id": protocol_id,
        "protocol_code": protocol.code,
        "active_users": {
            "24h": active_users_24h,
            "7d": active_users_7d,
            "30d": active_users_30d
        },
        "errors_count": errors,
        "period_days": days
    }

@router.get("/protocols/{protocol_id}/servers")
async def get_protocol_servers(
    protocol_id: int,
    admin_user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Список серверов, где протокол доступен"""
    protocol = db.query(Protocol).filter(Protocol.id == protocol_id).first()
    if not protocol:
        raise HTTPException(status_code=404, detail="Протокол не найден")
    
    # Получаем все серверы и проверяем, есть ли протокол в supported_protocols
    servers = db.query(Server).all()
    
    result = []
    for server in servers:
        supported_protocols = server.get_supported_protocols()
        if protocol.code in supported_protocols:
            result.append({
                "id": server.id,
                "name": server.name,
                "country": server.country,
                "status": server.status,
                "is_active": server.is_active
            })
    
    return result


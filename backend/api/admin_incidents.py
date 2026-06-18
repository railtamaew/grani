from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from datetime import datetime
from typing import List, Optional
from pydantic import BaseModel

from core.database import get_db
from core.rbac import require_support_or_above, get_current_admin_user as require_admin
from models.user import User
from models.telemetry import TelemetryEvent
from services.telemetry_service import TelemetryService

router = APIRouter()

class IncidentUpdate(BaseModel):
    status: Optional[str] = None  # new, investigating, resolved, ignored
    comment: Optional[str] = None

@router.get("/incidents")
async def get_incidents(
    user_id: Optional[int] = None,
    server_id: Optional[int] = None,
    protocol_code: Optional[str] = None,
    error_code: Optional[str] = None,
    app_version: Optional[str] = None,
    status: Optional[str] = None,
    skip: int = 0,
    limit: int = 100,
    admin_user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Список инцидентов с фильтрами"""
    telemetry_service = TelemetryService(db)
    
    incidents = telemetry_service.get_incidents(
        user_id=user_id,
        server_id=server_id,
        protocol_code=protocol_code,
        error_code=error_code,
        app_version=app_version,
        status=status,
        skip=skip,
        limit=limit
    )
    
    result = []
    for incident in incidents:
        # Получаем информацию о пользователе
        user_email = None
        if incident.user_id:
            user = db.query(User).filter(User.id == incident.user_id).first()
            if user:
                user_email = user.email
        
        result.append({
            "id": incident.id,
            "timestamp": incident.timestamp.isoformat() if incident.timestamp else None,
            "user_id": incident.user_id,
            "user_email": user_email,
            "device_id": incident.device_id,
            "protocol_code": incident.protocol_code,
            "server_id": incident.server_id,
            "event_type": incident.event_type,
            "error_code": incident.error_code,
            "error_message": incident.error_message,
            "country": incident.country,
            "network_type": incident.network_type,
            "status": incident.status,
            "app_version": incident.app_version
        })
    
    return result

@router.get("/incidents/{incident_id}")
async def get_incident_detail(
    incident_id: int,
    admin_user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Детальная карточка инцидента с таймлайном"""
    incident = db.query(TelemetryEvent).filter(TelemetryEvent.id == incident_id).first()
    if not incident:
        raise HTTPException(status_code=404, detail="Инцидент не найден")
    
    # Получаем последние 20 событий по user+device
    telemetry_service = TelemetryService(db)
    events = []
    if incident.user_id:
        events = telemetry_service.get_incident_events(
            user_id=incident.user_id,
            device_id=incident.device_id,
            limit=20
        )
    
    # Формируем таймлайн (connect_start -> fail)
    timeline = []
    connect_start = None
    for event in sorted(events, key=lambda x: x.timestamp if x.timestamp else datetime.min):
        if event.event_type == "connect_start":
            connect_start = event
        timeline.append({
            "id": event.id,
            "event_type": event.event_type,
            "timestamp": event.timestamp.isoformat() if event.timestamp else None,
            "error_code": event.error_code,
            "error_message": event.error_message,
            "duration_ms": event.duration_ms
        })
    
    # Информация о пользователе
    user_email = None
    if incident.user_id:
        user = db.query(User).filter(User.id == incident.user_id).first()
        if user:
            user_email = user.email
    
    # Рекомендуемое действие (простое правило)
    recommended_action = None
    if incident.error_code:
        if "timeout" in incident.error_code.lower():
            recommended_action = "Проверить доступность сервера и сетевую задержку"
        elif "auth" in incident.error_code.lower():
            recommended_action = "Проверить учетные данные пользователя"
        elif "dns" in incident.error_code.lower():
            recommended_action = "Проверить DNS настройки"
    
    return {
        "id": incident.id,
        "timestamp": incident.timestamp.isoformat() if incident.timestamp else None,
        "user_id": incident.user_id,
        "user_email": user_email,
        "device_id": incident.device_id,
        "protocol_code": incident.protocol_code,
        "server_id": incident.server_id,
        "event_type": incident.event_type,
        "error_code": incident.error_code,
        "error_message": incident.error_message,
        "country": incident.country,
        "network_type": incident.network_type,
        "status": incident.status,
        "app_version": incident.app_version,
        "os_version": incident.os_version,
        "platform": incident.platform,
        "timeline": timeline,
        "recommended_action": recommended_action
    }

@router.patch("/incidents/{incident_id}")
async def update_incident(
    incident_id: int,
    update: IncidentUpdate,
    admin_user: User = Depends(require_support_or_above),
    db: Session = Depends(get_db)
):
    """Обновление статуса инцидента"""
    incident = db.query(TelemetryEvent).filter(TelemetryEvent.id == incident_id).first()
    if not incident:
        raise HTTPException(status_code=404, detail="Инцидент не найден")
    
    if update.status:
        if update.status not in ["new", "investigating", "resolved", "ignored"]:
            raise HTTPException(status_code=400, detail="Недопустимый статус")
        incident.status = update.status
    
    # Можно добавить поле comment в модель TelemetryEvent для хранения комментариев
    # Пока просто обновляем статус
    
    db.commit()
    
    return {"message": "Инцидент обновлен"}

@router.get("/incidents/{incident_id}/events")
async def get_incident_events(
    incident_id: int,
    admin_user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Последние 20 событий по user+device для инцидента"""
    incident = db.query(TelemetryEvent).filter(TelemetryEvent.id == incident_id).first()
    if not incident:
        raise HTTPException(status_code=404, detail="Инцидент не найден")
    
    telemetry_service = TelemetryService(db)
    events = telemetry_service.get_incident_events(
        user_id=incident.user_id,
        device_id=incident.device_id,
        limit=20
    )
    
    return [
        {
            "id": e.id,
            "event_type": e.event_type,
            "timestamp": e.timestamp.isoformat() if e.timestamp else None,
            "error_code": e.error_code,
            "error_message": e.error_message,
            "duration_ms": e.duration_ms,
            "protocol_code": e.protocol_code,
            "server_id": e.server_id
        }
        for e in events
    ]


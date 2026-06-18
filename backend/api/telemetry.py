from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session
from pydantic import BaseModel
from typing import Optional
from datetime import datetime

from core.database import get_db
from services.telemetry_service import TelemetryService

router = APIRouter()

class ConnectEventRequest(BaseModel):
    user_id: Optional[int] = None
    device_id: Optional[int] = None
    protocol_code: Optional[str] = None
    server_id: Optional[int] = None
    event_type: str  # connect_start, connect_success, connect_fail, disconnect, etc.
    duration_ms: Optional[int] = None
    error_code: Optional[str] = None
    error_message: Optional[str] = None
    network_type: Optional[str] = None
    ip: Optional[str] = None
    country: Optional[str] = None
    app_version: Optional[str] = None
    os_version: Optional[str] = None
    platform: Optional[str] = None

@router.post("/connect_event")
async def record_connect_event(
    event: ConnectEventRequest,
    db: Session = Depends(get_db)
):
    """
    Публичный эндпоинт для записи событий подключения от приложений
    """
    telemetry_service = TelemetryService(db)
    
    telemetry_event = telemetry_service.record_event(
        user_id=event.user_id,
        device_id=event.device_id,
        protocol_code=event.protocol_code,
        server_id=event.server_id,
        event_type=event.event_type,
        duration_ms=event.duration_ms,
        error_code=event.error_code,
        error_message=event.error_message,
        network_type=event.network_type,
        ip=event.ip,
        country=event.country,
        app_version=event.app_version,
        os_version=event.os_version,
        platform=event.platform
    )
    
    return {
        "id": telemetry_event.id,
        "status": "recorded",
        "timestamp": telemetry_event.timestamp.isoformat()
    }




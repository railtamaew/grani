from sqlalchemy.orm import Session
from sqlalchemy import func, and_, or_, case
from datetime import datetime, timedelta
from typing import List, Optional, Dict, Any
from models.telemetry import TelemetryEvent
from models.server import Server
from models.protocol import Protocol

class TelemetryService:
    """Сервис для работы с телеметрией и инцидентами подключений"""
    
    def __init__(self, db: Session):
        self.db = db
    
    def record_event(
        self,
        user_id: Optional[int],
        device_id: Optional[int],
        protocol_code: Optional[str],
        server_id: Optional[int],
        event_type: str,
        duration_ms: Optional[int] = None,
        error_code: Optional[str] = None,
        error_message: Optional[str] = None,
        network_type: Optional[str] = None,
        ip: Optional[str] = None,
        country: Optional[str] = None,
        app_version: Optional[str] = None,
        os_version: Optional[str] = None,
        platform: Optional[str] = None
    ) -> TelemetryEvent:
        """
        Записывает событие подключения
        
        Returns:
            TelemetryEvent: Созданное событие
        """
        event = TelemetryEvent(
            user_id=user_id,
            device_id=device_id,
            protocol_code=protocol_code,
            server_id=server_id,
            event_type=event_type,
            timestamp=datetime.utcnow(),
            duration_ms=duration_ms,
            error_code=error_code,
            error_message=error_message,
            network_type=network_type,
            ip=ip,
            country=country,
            app_version=app_version,
            os_version=os_version,
            platform=platform,
            status="new" if error_code else None  # Если есть ошибка, создаем инцидент
        )
        
        self.db.add(event)
        self.db.commit()
        self.db.refresh(event)
        
        # Проверяем автоматические правила для пометки серверов как degraded
        if event_type == "connect_fail" and server_id:
            self._check_server_degraded(server_id)
        
        return event
    
    def get_incidents(
        self,
        user_id: Optional[int] = None,
        server_id: Optional[int] = None,
        protocol_code: Optional[str] = None,
        error_code: Optional[str] = None,
        app_version: Optional[str] = None,
        status: Optional[str] = None,
        skip: int = 0,
        limit: int = 100
    ) -> List[TelemetryEvent]:
        """
        Получает список инцидентов с фильтрами
        
        Returns:
            List[TelemetryEvent]: Список инцидентов
        """
        query = self.db.query(TelemetryEvent).filter(
            TelemetryEvent.error_code.isnot(None)  # Только события с ошибками
        )
        
        if user_id:
            query = query.filter(TelemetryEvent.user_id == user_id)
        
        if server_id:
            query = query.filter(TelemetryEvent.server_id == server_id)
        
        if protocol_code:
            query = query.filter(TelemetryEvent.protocol_code == protocol_code)
        
        if error_code:
            query = query.filter(TelemetryEvent.error_code == error_code)
        
        if app_version:
            query = query.filter(TelemetryEvent.app_version == app_version)
        
        if status:
            query = query.filter(TelemetryEvent.status == status)
        
        return query.order_by(TelemetryEvent.timestamp.desc()).offset(skip).limit(limit).all()
    
    def get_incident_events(self, user_id: int, device_id: Optional[int] = None, limit: int = 20) -> List[TelemetryEvent]:
        """
        Получает последние события по пользователю и устройству
        
        Returns:
            List[TelemetryEvent]: Список событий
        """
        query = self.db.query(TelemetryEvent).filter(
            TelemetryEvent.user_id == user_id
        )
        
        if device_id:
            query = query.filter(TelemetryEvent.device_id == device_id)
        
        return query.order_by(TelemetryEvent.timestamp.desc()).limit(limit).all()
    
    def analyze_failures(self, server_id: Optional[int] = None, protocol_code: Optional[str] = None, hours: int = 1) -> Dict[str, Any]:
        """
        Анализирует ошибки подключений
        
        Returns:
            Dict с анализом ошибок
        """
        since = datetime.utcnow() - timedelta(hours=hours)
        
        query = self.db.query(TelemetryEvent).filter(
            TelemetryEvent.event_type.in_(["connect_fail", "handshake_fail", "dns_fail", "timeout", "auth_fail", "server_unreachable"]),
            TelemetryEvent.timestamp >= since
        )
        
        if server_id:
            query = query.filter(TelemetryEvent.server_id == server_id)
        
        if protocol_code:
            query = query.filter(TelemetryEvent.protocol_code == protocol_code)
        
        error_code_col = func.coalesce(TelemetryEvent.error_code, "unknown")
        rows = (
            query.with_entities(error_code_col.label("error_code"), func.count().label("count"))
            .group_by(error_code_col)
            .all()
        )

        error_counts = {row.error_code: row.count for row in rows}
        total_failures = sum(row.count for row in rows)
        
        return {
            "total_failures": total_failures,
            "error_counts": error_counts,
            "period_hours": hours,
            "server_id": server_id,
            "protocol_code": protocol_code
        }
    
    def _check_server_degraded(self, server_id: int):
        """
        Проверяет, нужно ли пометить сервер как degraded
        (если fail_rate > X% за последние 10 минут)
        """
        ten_minutes_ago = datetime.utcnow() - timedelta(minutes=10)
        
        failure_types = [
            "connect_fail",
            "handshake_fail",
            "dns_fail",
            "timeout",
            "auth_fail",
            "server_unreachable",
        ]

        total_events, failed_events = self.db.query(
            func.count(TelemetryEvent.id),
            func.sum(
                case(
                    (TelemetryEvent.event_type.in_(failure_types), 1),
                    else_=0,
                )
            ),
        ).filter(
            TelemetryEvent.server_id == server_id,
            TelemetryEvent.timestamp >= ten_minutes_ago,
        ).one()

        if not total_events:
            return

        failed_events = failed_events or 0
        
        fail_rate = (failed_events / total_events) * 100
        
        # Если fail_rate > 30%, помечаем сервер как degraded
        if fail_rate > 30:
            server = self.db.query(Server).filter(Server.id == server_id).first()
            if server:
                # Можно добавить поле degraded в модель Server или использовать существующее поле status
                # Пока используем health_status
                server.health_status = "error"
                server.updated_at = datetime.utcnow()
                self.db.commit()




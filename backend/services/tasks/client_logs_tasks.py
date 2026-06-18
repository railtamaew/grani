"""
Фоновая обработка логов от клиентов (POST /api/vpn/logs/send).
Сохранение в БД выполняется в воркере, чтобы не блокировать ответ API.
"""
import logging
from datetime import datetime

from sqlalchemy.orm import Session

from core.database import SessionLocal
from models.user import User, Device
from models.server import Server
from models.client_log import ClientLog
from services.celery_app import celery_app
from core.metrics import metrics_registry
from core.observability_incidents import (
    classify_root_cause_from_client_log,
    upsert_session_connectivity_incident,
)

logger = logging.getLogger(__name__)


@celery_app.task(bind=True, name="vpn.save_client_logs")
def save_client_logs_task(self, user_id: int, device_id_str: str, logs: list) -> dict:
    """
    Сохраняет логи клиента в БД. Вызывается из API после приёма POST /api/vpn/logs/send.
    logs: список словарей из ClientLogEntry.model_dump().
    """
    db: Session = SessionLocal()
    try:
        user = db.query(User).filter(User.id == user_id).first()
        if not user:
            logger.warning("save_client_logs: user_id=%s not found", user_id)
            return {"ok": False, "error": "user not found", "logs_count": 0}

        device = (
            db.query(Device)
            .filter(Device.device_id == device_id_str, Device.user_id == user_id)
            .order_by(Device.created_at.desc().nullslast(), Device.id.desc())
            .first()
        )
        if not device:
            device = (
                db.query(Device)
                .filter(Device.device_id == device_id_str)
                .order_by(Device.created_at.desc())
                .first()
            )
            if device:
                device.user_id = user_id
                db.commit()
                db.refresh(device)
            else:
                logger.warning(
                    "save_client_logs: device_id=%s not found for user_id=%s",
                    device_id_str,
                    user_id,
                )
                return {"ok": False, "error": "device not found", "logs_count": 0}

        server_ids = {e.get("server_id") for e in logs if e.get("server_id")}
        servers_map = {}
        if server_ids:
            servers = (
                db.query(Server)
                .filter(Server.id.in_(server_ids), Server.is_active == True)
                .all()
            )
            servers_map = {s.id: s for s in servers}

        xray_protocols = {"xray_vless", "xray_vmess", "xray_reality"}
        health_updates: dict = {}

        for entry in logs:
            server = servers_map.get(entry.get("server_id")) if entry.get("server_id") else None
            if entry.get("server_id") and not server:
                logger.debug(
                    "save_client_logs: server_id=%s not found or inactive",
                    entry.get("server_id"),
                )

            error_details = dict(entry.get("error_details") or {})
            if entry.get("connection_session_id") is not None:
                error_details["connection_session_id"] = entry["connection_session_id"]
            if entry.get("trigger") is not None:
                error_details["trigger"] = entry["trigger"]

            client_log = ClientLog(
                user_id=user_id,
                device_id=device.id,
                server_id=entry.get("server_id") if server else None,
                event_type=entry.get("event_type", ""),
                protocol=entry.get("protocol"),
                client_id=entry.get("client_id"),
                message=entry.get("message"),
                error_code=entry.get("error_code"),
                error_details=error_details if error_details else None,
                app_version=entry.get("app_version"),
                platform=entry.get("platform"),
                os_version=entry.get("os_version"),
                connection_duration_ms=entry.get("connection_duration_ms"),
                bytes_sent=entry.get("bytes_sent"),
                bytes_received=entry.get("bytes_received"),
                vpn_session_id=entry.get("vpn_session_id") or entry.get("connection_session_id"),
            )
            db.add(client_log)
            metrics_registry.record_vpn_connectivity_event(
                event_type=entry.get("event_type", ""),
                message=entry.get("message"),
                details=error_details if error_details else None,
            )
            vpn_session_id = entry.get("vpn_session_id") or entry.get("connection_session_id")
            root_cause = classify_root_cause_from_client_log(
                event_type=entry.get("event_type", ""),
                message=entry.get("message"),
                error_details=error_details if error_details else None,
            )
            if root_cause and vpn_session_id:
                upsert_session_connectivity_incident(
                    db,
                    vpn_session_id=vpn_session_id,
                    root_cause=root_cause,
                    user_id=user_id,
                    server_id=entry.get("server_id") if server else None,
                    device_id=device.id,
                    protocol=entry.get("protocol"),
                    evidence={
                        "event_type": entry.get("event_type"),
                        "message": entry.get("message"),
                        "error_code": entry.get("error_code"),
                        "trigger": error_details.get("trigger"),
                    },
                )

            if server and entry.get("protocol") in xray_protocols:
                update = health_updates.setdefault(server.id, {"success": False, "error": False})
                if entry.get("event_type") in ("connection_success", "traffic_first_seen"):
                    update["success"] = True
                elif entry.get("event_type") in {"connection_error", "protocol_error"}:
                    update["error"] = True

        for sid, update in health_updates.items():
            server = servers_map.get(sid)
            if not server:
                continue
            if update.get("success"):
                server.health_status = "healthy"
                server.last_health_check = datetime.utcnow()
            elif update.get("error"):
                server.health_status = "warning"
                server.last_health_check = datetime.utcnow()

        db.commit()
        logger.info(
            "save_client_logs: saved logs_count=%s user_id=%s device_id=%s",
            len(logs),
            user_id,
            device_id_str,
        )
        return {"ok": True, "logs_count": len(logs)}
    except Exception as e:
        logger.exception("save_client_logs: user_id=%s error=%s", user_id, e)
        db.rollback()
        return {"ok": False, "error": str(e), "logs_count": 0}
    finally:
        db.close()

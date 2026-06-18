from fastapi import APIRouter, Depends, HTTPException, status, Request
from fastapi.responses import JSONResponse
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.orm import Session
from datetime import datetime
from typing import List, Optional, Dict, Any
from pydantic import BaseModel
import logging
import time
import uuid

from core.database import get_db
from core.http_diag import format_request_diag
from core.config import settings
from core.observability import emit_observability_event
from core.observability_incidents import (
    classify_root_cause_from_client_log,
    upsert_session_connectivity_incident,
)
from core.request_context import get_vpn_session_id
from core.metrics import metrics_registry
from models.user import User, Device
from models.server import Server
from models.client_log import ClientLog
from services.auth_service import AuthService

router = APIRouter(prefix="/api/vpn/logs", tags=["VPN Client Logs"])
logger = logging.getLogger(__name__)
security = HTTPBearer()


def _request_id_for_response(request: Request) -> str:
    return (
        request.headers.get("X-Request-ID")
        or request.headers.get("x-request-id")
        or str(uuid.uuid4())
    )


def _json_with_request_id(
    request: Request, content: dict, status_code: int = status.HTTP_200_OK
) -> JSONResponse:
    resp = JSONResponse(status_code=status_code, content=content)
    resp.headers["X-Request-ID"] = _request_id_for_response(request)
    return resp

# Pydantic модели для запросов
class ClientLogEntry(BaseModel):
    event_type: str  # connection_*, protocol_error, network_change, traffic_first_seen, connectivity_probe, ...
    protocol: Optional[str] = None
    client_id: Optional[str] = None
    message: Optional[str] = None
    error_code: Optional[str] = None
    error_details: Optional[Dict[str, Any]] = None
    app_version: Optional[str] = None
    platform: Optional[str] = None
    os_version: Optional[str] = None
    connection_duration_ms: Optional[int] = None
    bytes_sent: Optional[int] = None
    bytes_received: Optional[int] = None
    server_id: Optional[int] = None
    connection_session_id: Optional[str] = None  # ID сессии подключения для мониторинга
    trigger: Optional[str] = None  # first_connect | reconnect_after_network_change | reconnect_from_cache
    vpn_session_id: Optional[str] = None

class ClientLogRequest(BaseModel):
    device_id: str  # Строковый device_id
    logs: List[ClientLogEntry]

def _save_client_logs_sync(
    user_id: int,
    device_id: int,
    request_logs: list,
    db: Session,
    servers_map: dict,
) -> tuple[int, Dict[int, Dict[str, bool]]]:
    """Синхронное сохранение логов (используется при отсутствии Celery). Возвращает (saved_count, health_updates)."""
    saved_count = 0
    health_updates: Dict[int, Dict[str, bool]] = {}
    xray_protocols = {"xray_vless", "xray_vmess", "xray_reality"}
    for log_entry in request_logs:
        server = servers_map.get(log_entry.server_id) if log_entry.server_id else None
        if log_entry.server_id and not server:
            logger.warning(f"Сервер {log_entry.server_id} не найден или неактивен для лога пользователя {user_id}")

        error_details = dict(log_entry.error_details) if log_entry.error_details else {}
        if log_entry.connection_session_id is not None:
            error_details["connection_session_id"] = log_entry.connection_session_id
        if log_entry.trigger is not None:
            error_details["trigger"] = log_entry.trigger

        client_log = ClientLog(
            user_id=user_id,
            device_id=device_id,
            server_id=log_entry.server_id if server else None,
            event_type=log_entry.event_type,
            protocol=log_entry.protocol,
            client_id=log_entry.client_id,
            message=log_entry.message,
            error_code=log_entry.error_code,
            error_details=error_details if error_details else None,
            app_version=log_entry.app_version,
            platform=log_entry.platform,
            os_version=log_entry.os_version,
            connection_duration_ms=log_entry.connection_duration_ms,
            bytes_sent=log_entry.bytes_sent,
            bytes_received=log_entry.bytes_received,
            vpn_session_id=(
                log_entry.vpn_session_id
                or log_entry.connection_session_id
                or get_vpn_session_id()
            ),
        )
        db.add(client_log)
        saved_count += 1
        metrics_registry.record_vpn_connectivity_event(
            event_type=log_entry.event_type,
            message=log_entry.message,
            details=error_details if error_details else None,
        )
        vpn_session_id = (
            log_entry.vpn_session_id
            or log_entry.connection_session_id
            or get_vpn_session_id()
        )
        root_cause = classify_root_cause_from_client_log(
            event_type=log_entry.event_type,
            message=log_entry.message,
            error_details=error_details if error_details else None,
        )
        if root_cause and vpn_session_id:
            upsert_session_connectivity_incident(
                db,
                vpn_session_id=vpn_session_id,
                root_cause=root_cause,
                user_id=user_id,
                server_id=log_entry.server_id if server else None,
                device_id=device_id,
                protocol=log_entry.protocol,
                evidence={
                    "event_type": log_entry.event_type,
                    "message": log_entry.message,
                    "error_code": log_entry.error_code,
                    "trigger": error_details.get("trigger"),
                },
            )

        if server and log_entry.protocol in xray_protocols:
            update = health_updates.setdefault(server.id, {"success": False, "error": False})
            if log_entry.event_type in ("connection_success", "traffic_first_seen"):
                update["success"] = True
            elif log_entry.event_type in {"connection_error", "protocol_error"}:
                update["error"] = True

    for server_id, update in health_updates.items():
        server = servers_map.get(server_id)
        if not server:
            continue
        if update["success"]:
            server.health_status = "healthy"
            server.last_health_check = datetime.utcnow()
        elif update["error"]:
            server.health_status = "warning"
            server.last_health_check = datetime.utcnow()

    return saved_count, health_updates


@router.post("/send")
async def send_client_logs(
    request: ClientLogRequest,
    http_request: Request,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db)
):
    """
    Принимает логи подключений от клиентов для мониторинга и отладки.
    При доступном Celery логи сохраняются в фоне (ответ 202); иначе — синхронно (200).
    """
    t0 = time.perf_counter()
    diag = format_request_diag(http_request)
    user_id_timing: Optional[int] = None
    outcome = "unknown"
    n_logs = len(request.logs)
    device_id_str = request.device_id
    session_sample: List[str] = []
    for e in request.logs[:8]:
        if e.connection_session_id:
            session_sample.append(e.connection_session_id)
        if len(session_sample) >= 3:
            break
    try:
        user = AuthService.get_current_user(credentials.credentials, db)
        user_id_timing = user.id

        event_types = [e.event_type for e in request.logs]
        logger.info(
            "[client-logs-req] %s user_id=%s device_id=%s n=%s types=%s",
            diag,
            user.id,
            request.device_id,
            len(request.logs),
            event_types[:20],
        )
        logger.info(
            "Получен запрос на отправку логов: user_id=%s, email=%s, device_id=%s, logs_count=%s",
            user.id, user.email, request.device_id, len(request.logs)
        )
        emit_observability_event(
            db,
            event_name="VPN_CLIENT_LOGS_RECEIVED",
            severity="info",
            source="client",
            user_id=user.id,
            protocol="mixed",
            stage="ingest",
            outcome="success",
            message="Client logs payload received",
            attrs={"logs_count": len(request.logs), "device_id": request.device_id},
            commit=True,
        )

        device = db.query(Device).filter(
            Device.device_id == request.device_id,
            Device.user_id == user.id
        ).order_by(Device.created_at.desc().nullslast(), Device.id.desc()).first()

        if not device:
            device = db.query(Device).filter(Device.device_id == request.device_id).order_by(Device.created_at.desc()).first()
            if device:
                logger.warning(
                    "Device_id найден у другого пользователя. Перепривязываем device_id=%s от user_id=%s к user_id=%s",
                    request.device_id, device.user_id, user.id
                )
                device.user_id = user.id
                db.commit()
                db.refresh(device)
            else:
                all_devices = db.query(Device).filter(Device.user_id == user.id).all()
                device_ids = [d.device_id for d in all_devices]
                logger.warning(
                    "Устройство не найдено: device_id=%s, user_id=%s, email=%s",
                    request.device_id, user.id, user.email
                )
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail=f"Устройство не найдено. Запрошенный device_id: '{request.device_id}'. Доступные устройства: {device_ids}"
                )

        logger.info(
            "Устройство найдено: device_db_id=%s, device_string_id=%s, platform=%s",
            device.id, device.device_id, device.platform
        )

        # Пробуем поставить задачу в Celery
        try:
            from services.tasks.client_logs_tasks import save_client_logs_task
            logs_payload = [e.model_dump() for e in request.logs]
            save_client_logs_task.delay(user.id, request.device_id, logs_payload)
            logger.info(
                "Логи поставлены в очередь Celery: user_id=%s, device_id=%s, logs_count=%s",
                user.id, request.device_id, len(request.logs)
            )
            outcome = "queued"
            return _json_with_request_id(
                http_request,
                {
                    "ok": True,
                    "queued": True,
                    "message": f"Принято {len(request.logs)} логов, сохранение в фоне",
                    "logs_count": len(request.logs),
                },
                status_code=status.HTTP_202_ACCEPTED,
            )
        except Exception as _enqueue_err:
            logger.debug("Celery недоступен для логов, сохраняем синхронно: %s", _enqueue_err)

        # Синхронное сохранение (fallback)
        server_ids = {log_entry.server_id for log_entry in request.logs if log_entry.server_id}
        servers_map = {}
        if server_ids:
            servers = db.query(Server).filter(
                Server.id.in_(server_ids),
                Server.is_active == True
            ).all()
            servers_map = {s.id: s for s in servers}

        saved_count, _ = _save_client_logs_sync(
            user.id, device.id, request.logs, db, servers_map
        )
        for entry in request.logs:
            emit_observability_event(
                db,
                event_name=f"VPN_{(entry.event_type or 'CLIENT_EVENT').upper()}",
                severity="warn" if entry.error_code else "info",
                source="client",
                user_id=user.id,
                device_id=device.id,
                server_id=entry.server_id,
                protocol=entry.protocol,
                outcome="failure" if entry.error_code else "success",
                reason_code=entry.error_code,
                message=entry.message,
                vpn_session_id=entry.vpn_session_id,
                attrs=entry.error_details or {},
            )
        db.commit()

        logger.info("Сохранено %s логов от пользователя %s, устройство %s", saved_count, user.id, request.device_id)

        outcome = "sync_ok"
        return _json_with_request_id(
            http_request,
            {
                "ok": True,
                "message": f"Сохранено {saved_count} логов",
                "logs_count": saved_count,
            },
        )

    except HTTPException as he:
        outcome = f"http_{he.status_code}"
        raise
    except Exception as e:
        outcome = "error"
        logger.error("Ошибка сохранения логов: %s", e, exc_info=True)
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Ошибка сохранения логов: {str(e)}"
        )
    finally:
        try:
            elapsed_ms = int((time.perf_counter() - t0) * 1000)
            logger.info(
                "[client-logs-timing] %s user_id=%s device_id=%s n=%s outcome=%s elapsed_ms=%s session_sample=%s",
                diag,
                user_id_timing,
                device_id_str,
                n_logs,
                outcome,
                elapsed_ms,
                session_sample,
            )
        except Exception:
            pass

# Публичный endpoint для тестовых логов (без авторизации)
class TestLogEntry(BaseModel):
    timestamp: str
    level: str  # DEBUG, INFO, WARN, ERROR
    tag: str
    message: str
    extra: Optional[Dict[str, Any]] = None

class TestLogRequest(BaseModel):
    app: str  # Название приложения (например, "vpn-minimal")
    logs: List[TestLogEntry]

@router.post("/test")
async def send_test_logs(
    request: TestLogRequest,
    db: Session = Depends(get_db)
):
    """
    Публичный endpoint для тестовых логов от минимального приложения (без авторизации).
    Используется для отладки и тестирования VPN протоколов.
    """
    try:
        logger.info(f"Получены тестовые логи от {request.app}: {len(request.logs)} записей")
        
        # Сохраняем логи в файл для анализа
        import os
        log_dir = settings.client_test_logs_dir
        # Пытаемся использовать директорию, если не получается - используем /tmp
        try:
            # Просто пытаемся открыть файл для записи, не проверяя существование директории
            test_file = os.path.join(log_dir, ".test_write")
            with open(test_file, "w") as f:
                f.write("test")
            os.remove(test_file)
        except (PermissionError, OSError) as e:
            logger.warning(f"Не удалось писать в {log_dir}: {e}, используем /tmp")
            log_dir = "/tmp/vpn_minimal_logs"
            os.makedirs(log_dir, exist_ok=True)
        
        log_file = os.path.join(log_dir, f"{request.app}_{datetime.now().strftime('%Y%m%d')}.log")
        
        with open(log_file, "a", encoding="utf-8") as f:
            for log_entry in request.logs:
                extra_str = ""
                if log_entry.extra:
                    extra_str = f" | extra: {log_entry.extra}"
                f.write(f"{log_entry.timestamp} | {log_entry.level} | {log_entry.tag} | {log_entry.message}{extra_str}\n")
        
        logger.debug(f"Тестовые логи сохранены в {log_file}")
        
        return {
            "ok": True,
            "message": f"Получено {len(request.logs)} логов",
            "logs_count": len(request.logs),
            "saved_to": log_file
        }
        
    except Exception as e:
        logger.error(f"Ошибка сохранения тестовых логов: {e}", exc_info=True)
        # Не выбрасываем исключение, чтобы не ломать тестирование
        return {
            "ok": False,
            "message": f"Ошибка сохранения: {str(e)}",
            "logs_count": len(request.logs) if request else 0
        }

from fastapi import APIRouter, Depends, HTTPException, status, Request, Query
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.orm import Session
from typing import List, Dict, Any, Optional
from pydantic import BaseModel
from datetime import datetime
import logging
import asyncio
import time

from core.database import get_db
from core.perf_logging import perf_logger
from core.dependencies import get_vpn_operations_service
from core.async_utils import run_sync
from models.user import User, Device
from models.server import Server
from application.services.vpn_operations_service import VPNOperationsService, ConnectionConfigView

router = APIRouter(prefix="/api/vpn/xray", tags=["Xray VPN"])
logger = logging.getLogger(__name__)
security = HTTPBearer()


def _nth_apply_state_longpoll_sleep_sec(attempt_index: int, max_attempts: int) -> float:
    """Короче в начале, затем до 1s — как раньше не больше max_attempts итераций."""
    if max_attempts <= 1:
        return 1.0
    if attempt_index < min(4, max_attempts):
        return 0.25
    if attempt_index < min(12, max_attempts):
        return 0.5
    return 1.0

# Схемы запросов и ответов
class VPNConnectionRequest(BaseModel):
    server_id: int
    device_id: Optional[str] = None
    protocol: Optional[str] = "xray_vless"  # xray_vless, xray_vmess, xray_reality
    name: Optional[str] = None  # Имя устройства (для auto_register)
    platform: Optional[str] = None  # android, ios, unknown (для auto_register)
    fingerprint: Optional[str] = None  # для merge/resolve после переустановки

class VPNConnectionResponse(BaseModel):
    success: bool
    client_id: Optional[str] = None
    config: Optional[str] = None
    protocol: Optional[str] = None
    server_name: Optional[str] = None
    ip_address: Optional[str] = None
    message: Optional[str] = None
    apply_required: Optional[bool] = None

class VPNStatsResponse(BaseModel):
    total_uplink: int
    total_downlink: int
    active_clients: int
    total_clients: int
    timestamp: str
    protocol: str


class XrayApplyStateResponse(BaseModel):
    server_id: int
    requested_config_revision: str
    matched: bool
    status: str
    is_applied: bool
    wait_for: Optional[str] = None
    timeout_sec: Optional[int] = None
    waited_ms: Optional[int] = None
    timed_out: Optional[bool] = None
    retry_after_sec: Optional[int] = None
    apply_state: Optional[Dict[str, Any]] = None
    edge_assignment: Optional[Dict[str, Any]] = None
    reason_code: Optional[str] = None
    active_xray_sessions: Optional[int] = None
    phase: Optional[str] = None
    node_health: Optional[str] = None
    retry_after: Optional[int] = None
    partial_ack_state: Optional[str] = None
    pending_reason: Optional[str] = None
    pending_flags: Optional[List[str]] = None


class XrayCommitRequest(BaseModel):
    server_id: int


@router.post("/create-client")
async def create_xray_client(
    request: VPNConnectionRequest,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service)
):
    """
    Создает Xray клиента для устройства. Без device_id — один коннект на (user, server, protocol).

    Предпочтительный путь для новых клиентов: POST /api/vpn/session/prepare (тот же контракт для xray_*).
    """
    logger.info(
        "create-client: входящий запрос server_id=%s device_id=%s protocol=%s",
        request.server_id,
        request.device_id or "(none)",
        request.protocol or "xray_vless",
    )
    try:
        from services.auth_service import AuthService
        user = AuthService.get_current_user(credentials.credentials, vpn_service.db)
        server = vpn_service.validate_and_get_server(request.server_id)
        protocol = request.protocol or "xray_vless"

        if not request.device_id or not request.device_id.strip():
            # Session ORM — только поток обработчика (без to_thread для этой БД-цепочки).
            result = vpn_service.get_or_create_connection(user, server, protocol)
            return {
                k: v
                for k, v in result.items()
                if k
                in (
                    "success",
                    "client_id",
                    "config",
                    "json_config",
                    "config_revision",
                    "payload_fingerprint",
                    "apply_state",
                    "apply_config_revision",
                    "apply_config_sha256",
                    "active_config_hash",
                    "runtime_contract",
                    "correlation_id",
                    "phase",
                    "node_health",
                    "retry_after",
                    "apply_required",
                    "protocol",
                    "server_name",
                    "ip_address",
                    "message",
                )
            }
        device_data = {
            "name": request.name or f"Device {request.device_id[:8]}",
            "device_id": request.device_id,
            "platform": request.platform or "unknown",
        }
        if request.fingerprint and request.fingerprint.strip():
            device_data["fingerprint"] = request.fingerprint.strip()
        device = vpn_service.validate_and_get_device(
            user,
            request.device_id,
            auto_register=True,
            device_data=device_data,
        )
        result = vpn_service.create_xray_client(user, device, server, protocol)
        return result
        
    except HTTPException:
        raise
    except Exception as e:
        from core.error_types import AppException
        if isinstance(e, AppException):
            raise  # Пробрасываем для general_exception_handler (сохраняет devices в ответе)
        import traceback
        error_trace = traceback.format_exc()
        error_message = str(e) if str(e) else "Неизвестная ошибка"
        logger.error(f"Ошибка создания Xray клиента: {error_message}")
        logger.error(f"Stack trace:\n{error_trace}")
        logger.error(f"Детали ошибки: request={request}, user_id={user.id if 'user' in locals() else 'unknown'}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Ошибка создания клиента: {error_message}"
        )

@router.get("/config/{client_id}")
async def get_xray_config(
    client_id: str,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service)
):
    """Получает конфигурацию Xray клиента"""
    try:
        # Получаем пользователя из токена
        from services.auth_service import AuthService
        user = AuthService.get_current_user(credentials.credentials, vpn_service.db)
        
        device_or_view = vpn_service.get_device_by_client_id(user, client_id)
        return await run_sync(vpn_service.get_xray_config, user, device_or_view)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Ошибка получения конфигурации: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Ошибка получения конфигурации"
        )

@router.delete("/client/{client_id}")
async def delete_xray_client(
    client_id: str,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service)
):
    """Удаляет Xray клиента"""
    try:
        # Получаем пользователя из токена
        from services.auth_service import AuthService
        user = AuthService.get_current_user(credentials.credentials, vpn_service.db)
        
        # Получаем устройство по client_id
        try:
            device = vpn_service.get_device_by_client_id(user, client_id)
        except HTTPException as exc:
            if exc.status_code == status.HTTP_404_NOT_FOUND:
                return {
                    "success": True,
                    "message": "Клиент уже удален"
                }
            raise
        
        # Удаляем клиента
        return await run_sync(vpn_service.delete_xray_client, user, device)
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Ошибка удаления Xray клиента: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Ошибка удаления клиента"
        )


@router.get("/apply-state", response_model=XrayApplyStateResponse)
async def get_xray_apply_state(
    request: Request,
    server_id: int = Query(..., description="ID VPN сервера"),
    config_revision: str = Query(..., description="Ревизия конфига из create-client/config"),
    wait_for: Optional[str] = Query(
        None,
        description="Опционально: 'applied' для long-poll ожидания применения",
    ),
    timeout_sec: int = Query(
        0,
        ge=0,
        le=30,
        description="Таймаут long-poll в секундах (0 = без ожидания)",
    ),
    credentials: HTTPAuthorizationCredentials = Depends(security),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service),
):
    """
    Возвращает статус применения Xray-конфига для указанной revision.
    Нужен мобильному клиенту для явного ACK, что сервер применил нужный конфиг.
    """
    try:
        from services.auth_service import AuthService

        user = AuthService.get_current_user(credentials.credentials, vpn_service.db)
        req_id = (
            request.headers.get("x-request-id")
            or request.headers.get("X-Request-ID")
            or getattr(request.state, "request_id", None)
        )
        logger.info(
            "xray apply-state start user_id=%s server_id=%s revision=%s wait_for=%s "
            "timeout_sec=%s request_id=%s",
            user.id,
            server_id,
            config_revision,
            wait_for,
            timeout_sec,
            req_id,
        )
        if wait_for and wait_for != "applied":
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Поддерживается только wait_for=applied",
            )

        t0 = time.monotonic()
        response = await run_sync(vpn_service.get_xray_apply_state, user, server_id, config_revision)

        if wait_for == "applied" and timeout_sec > 0:
            from core.config import settings
            from core.xray_apply_notify import (
                blocking_wait_xray_apply,
                should_use_apply_pubsub_wait,
            )

            max_attempts = max(1, int(timeout_sec))
            use_pubsub = should_use_apply_pubsub_wait()
            redis_url = getattr(settings, "redis_url", "") or ""

            for attempt in range(max_attempts):
                if response.get("is_applied") or response.get("status") in {
                    "failed",
                    "error",
                }:
                    break
                if response.get("partial_ack_state") == "committed_dataplane":
                    break
                chunk = _nth_apply_state_longpoll_sleep_sec(attempt, max_attempts)
                pub_budget = min(0.35, chunk) if use_pubsub else 0.0
                if pub_budget > 0.02:
                    await asyncio.to_thread(
                        blocking_wait_xray_apply,
                        redis_url,
                        server_id,
                        config_revision,
                        pub_budget,
                    )
                rest = max(0.0, chunk - pub_budget)
                if rest > 0:
                    await asyncio.sleep(rest)
                response = await run_sync(
                    vpn_service.get_xray_apply_state,
                    user,
                    server_id,
                    config_revision,
                )

            response["wait_for"] = wait_for
            response["timeout_sec"] = timeout_sec
            response["waited_ms"] = int((time.monotonic() - t0) * 1000)
            has_partial_ack = response.get("partial_ack_state") == "committed_dataplane"
            response["timed_out"] = not (
                response.get("is_applied")
                or has_partial_ack
                or response.get("status") in {"failed", "error"}
            )
            response["retry_after_sec"] = (
                2
                if response["timed_out"] and not response.get("is_applied") and not has_partial_ack
                else 0
            )
            perf_logger.warning(
                "[perf] xray_apply_state_longpoll req_id=%s waited_ms=%s timed_out=%s "
                "is_applied=%s server_id=%s",
                req_id,
                response.get("waited_ms"),
                response.get("timed_out"),
                response.get("is_applied"),
                server_id,
            )
            return response

        response["wait_for"] = wait_for
        response["timeout_sec"] = timeout_sec
        response["waited_ms"] = int((time.monotonic() - t0) * 1000)
        response["timed_out"] = False
        response["retry_after_sec"] = 0
        perf_logger.warning(
            "[perf] xray_apply_state_snapshot req_id=%s waited_ms=%s is_applied=%s server_id=%s",
            req_id,
            response.get("waited_ms"),
            response.get("is_applied"),
            server_id,
        )
        return response
    except HTTPException:
        raise
    except Exception as e:
        logger.error("Ошибка получения apply-state Xray: %s", e, exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Ошибка получения apply-state",
        )


@router.post("/commit-staged")
async def commit_staged_xray_config(
    request_data: XrayCommitRequest,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service),
):
    """
    Явный phase-2 commit staged конфига Xray.
    Нужен для rollout, где /session/prepare не делает apply мгновенно.
    """
    try:
        from services.auth_service import AuthService

        AuthService.get_current_user(credentials.credentials, vpn_service.db)
        server = vpn_service.validate_and_get_server(request_data.server_id)
        result = await run_sync(vpn_service.xray_manager.commit_staged_config, server)
        return {
            "server_id": server.id,
            "result": result,
        }
    except HTTPException:
        raise
    except Exception as e:
        logger.error("Ошибка commit staged Xray: %s", e, exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Ошибка commit staged Xray",
        )


@router.get("/stats")
async def get_xray_stats(
    server_id: Optional[int] = None,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service)
):
    """Получает статистику Xray сервера"""
    try:
        # Получаем пользователя из токена
        from services.auth_service import AuthService
        user = AuthService.get_current_user(credentials.credentials, vpn_service.db)
        
        # Получаем сервер, если указан
        server = None
        if server_id:
            server = vpn_service.validate_and_get_server(server_id)
        
        # Получаем статистику
        return await run_sync(vpn_service.get_xray_stats, server)
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Ошибка получения статистики: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Ошибка получения статистики"
        )

@router.get("/client-stats/{client_id}")
async def get_xray_client_stats(
    client_id: str,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service)
):
    """Получает статистику конкретного клиента"""
    try:
        # Получаем пользователя из токена
        from services.auth_service import AuthService
        user = AuthService.get_current_user(credentials.credentials, vpn_service.db)
        
        # Получаем устройство по client_id
        device = vpn_service.get_device_by_client_id(user, client_id)
        
        # Получаем статистику клиента
        return vpn_service.get_xray_client_stats(user, device)
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Ошибка получения статистики клиента: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Ошибка получения статистики"
        )

@router.get("/health")
async def check_xray_health(
    server_id: Optional[int] = Query(None, description="ID сервера для проверки"),
    credentials: HTTPAuthorizationCredentials = Depends(security),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service)
):
    """Проверяет здоровье Xray сервера"""
    try:
        # Получаем пользователя из токена
        from services.auth_service import AuthService
        user = AuthService.get_current_user(credentials.credentials, vpn_service.db)
        
        # Получаем сервер, если указан
        server = None
        if server_id:
            server = vpn_service.validate_and_get_server(server_id)
        else:
            # Получаем первый активный сервер
            server = vpn_service.db.query(Server).filter(
                Server.is_active == True
            ).first()
            if not server:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail="Активные серверы не найдены"
                )
        
        health = await run_sync(vpn_service.xray_manager.check_server_health, server)
        return health
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Ошибка проверки здоровья: {e}")
        return {
            "status": "error",
            "message": str(e)
        }

@router.get("/clients")
async def get_all_xray_clients(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service)
):
    """Получает список всех Xray клиентов пользователя"""
    try:
        # Получаем пользователя из токена
        from services.auth_service import AuthService
        user = AuthService.get_current_user(credentials.credentials, vpn_service.db)
        
        # Получаем все устройства пользователя с Xray клиентами
        devices = vpn_service.db.query(Device).filter(
            Device.user_id == user.id,
            Device.vpn_client_id.isnot(None)
        ).all()
        
        user_clients = []
        for device in devices:
            user_clients.append({
                "client_id": device.vpn_client_id,
                "device_id": device.device_id,
                "protocol": device.vpn_protocol if hasattr(device, 'vpn_protocol') else None,
                "created_at": device.created_at.isoformat() if device.created_at else None
            })
        
        return {
            "clients": user_clients,
            "total": len(user_clients)
        }
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Ошибка получения списка клиентов: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Ошибка получения списка клиентов"
        )

@router.post("/switch-protocol")
async def switch_xray_protocol(
    client_id: str,
    new_protocol: str,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service)
):
    """Переключает протокол для существующего клиента"""
    try:
        # Получаем пользователя из токена
        from services.auth_service import AuthService
        user = AuthService.get_current_user(credentials.credentials, vpn_service.db)
        
        # Проверяем поддерживаемые протоколы
        if new_protocol not in ['vless', 'vmess']:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Неподдерживаемый протокол"
            )
        
        # Получаем устройство по client_id
        device = vpn_service.get_device_by_client_id(user, client_id)
        
        # Получаем сервер
        if not device.current_server_id:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Сервер не найден"
            )
        
        server = vpn_service.validate_and_get_server(device.current_server_id)
        
        # Удаляем старый клиент и создаём нового (ORM session — тот же поток, без to_thread).
        vpn_service.delete_xray_client(user, device)
        result = vpn_service.create_xray_client(user, device, server, new_protocol)
        
        return {
            "success": True,
            "new_client_id": result['client_id'],
            "protocol": new_protocol,
            "config": result['config'],
            "message": f"Протокол успешно изменен на {new_protocol}"
        }
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Ошибка переключения протокола: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Ошибка переключения протокола"
        )


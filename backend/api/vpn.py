from fastapi import APIRouter, Depends, HTTPException, status, Request
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.orm import Session
from datetime import datetime
from typing import List, Optional
import asyncio
import subprocess
import json
import logging
import time

from core.config import settings
from core.database import get_db
from core.async_utils import run_sync
from core.rbac import get_current_admin_user
from core.constants import (
    WIREGUARD_DEFAULT_PORT,
    DEFAULT_MAX_USERS_PER_SERVER
)

logger = logging.getLogger(__name__)
try:
    from core.dependencies import get_vpn_operations_service
    from services.vpn_operations_service import VPNOperationsService
    VPN_SERVICES_AVAILABLE = True
except ImportError as e:
    get_vpn_operations_service = None
    VPNOperationsService = None
    VPN_SERVICES_AVAILABLE = False
    logger.warning(f"VPN сервисы недоступны: {e}")

from models.user import User, Device
from models.subscription import Subscription
from models.server import Server, ConnectionLog
from models.protocol import Protocol
from services.auth_service import AuthService
from services.device_manager import DeviceManager
from pydantic import BaseModel
from core.error_types import AppException
from core.cache import cache_get, cache_set
from core.observability import emit_observability_event
from core.request_context import get_request_id

router = APIRouter()

# Короткий кэш ответа prepare для xray_* — снимает дубли SSH при двойном тапе / ретраях.
# Увеличен TTL, чтобы чаще попадать в hit при повторных connect в том же окне.
SESSION_PREPARE_CACHE_TTL_SEC = 300
# Параллельные запросы с тем же ключом ждут один lock — второй не запускает второй SSH, пока первый не положит кэш.
_session_prepare_locks: dict[str, asyncio.Lock] = {}

def _session_prepare_lock_for_key(cache_key: str) -> asyncio.Lock:
    lock = _session_prepare_locks.get(cache_key)
    if lock is None:
        lock = asyncio.Lock()
        _session_prepare_locks[cache_key] = lock
    return lock

security = HTTPBearer()

# Pydantic модели
class DeviceRegister(BaseModel):
    device_id: str
    name: Optional[str] = None
    platform: str  # ios, android, desktop
    public_key: Optional[str] = None
    private_key: Optional[str] = None
    fingerprint: Optional[str] = None  # хеш для resolve после переустановки

class DeviceResolveRequest(BaseModel):
    fingerprint: str
    name: Optional[str] = None
    platform: Optional[str] = None

class PushTokenUpdate(BaseModel):
    push_token: str
    language: Optional[str] = None

class VPNStatus(BaseModel):
    connected: bool
    ip_address: Optional[str] = None
    server: Optional[dict] = None
    stats: Optional[dict] = None
    connected_since: Optional[str] = None

class ServerInfo(BaseModel):
    id: int
    name: str
    country: str
    city: Optional[str] = None
    ip_address: str
    port: int
    current_users: int
    max_users: int
    is_active: bool
    health_status: Optional[str] = None
    supported_protocols: Optional[List[str]] = None
    wireguard_port: Optional[int] = None
    wireguard_public_key: Optional[str] = None
    flag_url: Optional[str] = None
    # Задержка до ноды (ICMP или TCP connect fallback), обновляется мониторингом
    ping_ms: Optional[float] = None
    xray_port: Optional[int] = None

@router.post("/device/register")
async def register_device(
    device_data: DeviceRegister,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service)
):
    """Регистрация устройства"""
    try:
        # Получаем пользователя из токена
        from services.auth_service import AuthService
        user = AuthService.get_current_user(credentials.credentials, vpn_service.db)
        logger.info(f"Регистрация устройства: user_id={user.id}, device_id={device_data.device_id}, platform={device_data.platform}")
        
        # Используем сервис для регистрации устройства
        device_payload = {
            'name': device_data.name or f"Device {device_data.device_id}",
            'device_id': device_data.device_id,
            'platform': device_data.platform
        }
        if device_data.public_key:
            device_payload['public_key'] = device_data.public_key
        if device_data.private_key:
            device_payload['private_key'] = device_data.private_key
        if device_data.fingerprint:
            device_payload['fingerprint'] = device_data.fingerprint

        device = vpn_service.register_device(user, device_payload)

        # Кардинальный decouple: register создаёт только DB-identity без SSH/apply на ноде.
        # Реальный server-side create/apply выполняется лениво на first real connect.
        preprovision_client_id = getattr(device, "vpn_client_id", None)
        if not preprovision_client_id:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="Логический client_id не назначен при регистрации устройства",
            )

        return {
            "message": "Устройство зарегистрировано",
            "device_id": device.id,
            "preprovisioned": False,
            "client_id": preprovision_client_id,
        }
        
    except AppException:
        raise
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Неожиданная ошибка при регистрации устройства: {e}", exc_info=True)
        raise HTTPException(status_code=400, detail=f"Ошибка регистрации устройства: {str(e)}")


@router.post("/device/push-token")
async def update_push_token(
    data: PushTokenUpdate,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
):
    """Сохранение/обновление FCM push-токена пользователя."""
    try:
        from services.auth_service import AuthService
        user_schema = AuthService.get_current_user(credentials.credentials, db)

        # Получаем ORM-модель пользователя и сохраняем токен на уровне пользователя.
        db_user = db.query(User).filter(User.id == user_schema.id).first()
        if not db_user:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Пользователь не найден",
            )

        # Один FCM-токен = одно устройство: снимаем его с других пользователей,
        # иначе пуш по подписке «целевого» аккаунта уходит на устройство, где в БД
        # токен ещё числится за предыдущим логином.
        db.query(User).filter(
            User.push_token == data.push_token,
            User.id != db_user.id,
        ).update({"push_token": None}, synchronize_session=False)

        db_user.push_token = data.push_token
        if data.language:
            normalized = data.language.strip().lower()
            if normalized in {"en", "ru"}:
                db_user.preferred_language = normalized
        db.commit()
        logger.info("push-token обновлён для user_id=%s", db_user.id)
        return {"ok": True}
    except HTTPException:
        raise
    except Exception as e:
        logger.error("Ошибка обновления push-token: %s", e, exc_info=True)
        raise HTTPException(status_code=400, detail=str(e))


@router.post("/device/resolve")
async def resolve_device(
    request_data: DeviceResolveRequest,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service)
):
    """Разрешение device_id по fingerprint (после переустановки/очистки данных). Возвращает существующий или создаёт новое устройство."""
    try:
        user = AuthService.get_current_user(credentials.credentials, vpn_service.db)
        device_id = vpn_service.resolve_device(
            user,
            request_data.fingerprint,
            name=request_data.name,
            platform=request_data.platform,
        )
        return {"device_id": device_id}
    except AppException:
        raise
    except HTTPException:
        raise
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        logger.error(f"Ошибка resolve устройства: {e}", exc_info=True)
        raise HTTPException(status_code=400, detail=f"Ошибка resolve устройства: {str(e)}")


class DeviceDeleteRequest(BaseModel):
    device_id: str


@router.post("/device/delete")
async def delete_user_device(
    request_data: DeviceDeleteRequest,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
):
    """Полное удаление устройства пользователем (уменьшает счётчик устройств)."""
    try:
        user = AuthService.get_current_user(credentials.credentials, db)
        device = db.query(Device).filter(
            Device.device_id == request_data.device_id,
            Device.user_id == user.id,
        ).first()
        if not device:
            raise HTTPException(status_code=404, detail="Устройство не найдено")

        devices_to_delete = db.query(Device).filter(
            Device.device_id == request_data.device_id,
            Device.user_id == user.id,
        ).all()
        device_db_ids = [d.id for d in devices_to_delete]
        from models.server import ConnectionLog as CLog
        if device_db_ids:
            db.query(CLog).filter(CLog.device_id.in_(device_db_ids)).delete(synchronize_session=False)
        try:
            from domain.models.telemetry import TelemetryEvent
            if device_db_ids:
                db.query(TelemetryEvent).filter(TelemetryEvent.device_id.in_(device_db_ids)).update(
                    {"device_id": None}, synchronize_session=False)
        except Exception:
            pass
        try:
            from domain.models.client_log import ClientLog
            if device_db_ids:
                db.query(ClientLog).filter(ClientLog.device_id.in_(device_db_ids)).delete(synchronize_session=False)
        except Exception:
            pass
        try:
            from domain.models.observability import ObservabilityEvent
            if device_db_ids:
                db.query(ObservabilityEvent).filter(
                    ObservabilityEvent.device_id.in_(device_db_ids)
                ).update({"device_id": None}, synchronize_session=False)
        except Exception:
            pass
        for row in devices_to_delete:
            db.delete(row)
        db.commit()

        try:
            from core.cache import invalidate_user_cache, cache_delete
            invalidate_user_cache(user.id)
            cache_delete(f"cache:devices:{user.id}")
        except Exception:
            pass

        remaining = (
            db.query(Device.device_id)
            .filter(Device.user_id == user.id)
            .distinct()
            .count()
        )
        logger.info(
            "Устройство удалено пользователем: user_id=%s, device_id=%s, rows_deleted=%s, remaining_distinct=%s",
            user.id,
            request_data.device_id,
            len(devices_to_delete),
            remaining,
        )
        return {"message": "Устройство удалено", "remaining_devices": remaining}
    except HTTPException:
        raise
    except Exception as e:
        db.rollback()
        logger.error(f"Ошибка удаления устройства: {e}", exc_info=True)
        raise HTTPException(status_code=400, detail=f"Ошибка удаления устройства: {str(e)}")


class ConnectVPNRequest(BaseModel):
    server_id: int
    device_id: Optional[str] = None  # опционально: при отсутствии используется единый алгоритм (один коннект на user+server+protocol)
    protocol: Optional[str] = "xray_vless"  # xray_vless, xray_vmess, xray_reality
    fingerprint: Optional[str] = None  # хеш для сохранения при auto-register (resolve после переустановки)

class DisconnectVPNRequest(BaseModel):
    device_id: Optional[str] = None
    force: Optional[bool] = False  # Принудительное отключение (пропускает удаление пира/клиента)


@router.post("/session/prepare")
async def prepare_vpn_session(
    request_data: ConnectVPNRequest,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    vpn_service=Depends(get_vpn_operations_service),
):
    """
    Единая точка выдачи конфигурации для клиента.
    Для протоколов xray_* — тот же контракт, что POST /api/vpn/xray/create-client;
    иначе — поведение POST /api/vpn/connect.
    """
    start_ts = time.monotonic()
    stage_ts = start_ts
    log_status = 200
    user_id_log = "unknown"
    session_prepare_cache = "n/a"  # hit|miss|non_xray — для метрик
    protocol = (request_data.protocol or "xray_vless").strip()
    user = None
    req_id_log = get_request_id()
    lock_wait_ms = 0
    create_client_ms = 0
    cache_get_ms = 0
    cache_set_ms = 0
    payload_fingerprint = ""
    active_config_hash = ""

    def _log_stage(stage: str) -> None:
        nonlocal stage_ts
        now = time.monotonic()
        logger.warning(
            "[session_prepare_stage] req_id=%s stage=%s dt_ms=%s user_id=%s server_id=%s protocol=%s cache=%s",
            req_id_log,
            stage,
            int((now - stage_ts) * 1000),
            user_id_log,
            request_data.server_id,
            protocol,
            session_prepare_cache,
        )
        stage_ts = now
    try:
        emit_observability_event(
            vpn_service.db,
            event_name="VPN_CONNECT_PREPARE_STARTED",
            severity="info",
            source="backend",
            server_id=request_data.server_id,
            protocol=protocol,
            stage="prepare",
            outcome="started",
            attrs={"device_id": request_data.device_id},
            commit=True,
        )
        try:
            user = AuthService.get_current_user(credentials.credentials, vpn_service.db)
            user_id_log = user.id
        except Exception:
            pass
        _log_stage("after_auth")

        if protocol.startswith("xray_"):
            if user is None:
                raise HTTPException(
                    status_code=status.HTTP_401_UNAUTHORIZED,
                    detail="Неверный или просроченный токен",
                )

            device_key = (request_data.device_id or "").strip() or "_none"
            cache_key = (
                f"session_prepare:{user.id}:{request_data.server_id}:"
                f"{device_key}:{protocol}"
            )
            logger.warning(
                "[session_prepare_begin] req_id=%s user_id=%s server_id=%s "
                "device_key=%s protocol=%s cache_key=%s read_only=%s",
                req_id_log,
                user.id,
                request_data.server_id,
                device_key,
                protocol,
                cache_key,
                False,
            )

            fast_cache_start = time.monotonic()
            cached_fast = cache_get(cache_key)
            fast_cache_ms = int((time.monotonic() - fast_cache_start) * 1000)
            if cached_fast is not None:
                session_prepare_cache = "hit"
                cache_get_ms = fast_cache_ms
                if isinstance(cached_fast, dict):
                    payload_fingerprint = str(cached_fast.get("payload_fingerprint") or cached_fast.get("config_revision") or "")
                    active_config_hash = str(cached_fast.get("active_config_hash") or cached_fast.get("apply_config_sha256") or "")
                _log_stage("cache_hit_fast")
                return cached_fast

            lock = _session_prepare_lock_for_key(cache_key)
            lock_wait_start = time.monotonic()
            async with lock:
                lock_wait_ms = int((time.monotonic() - lock_wait_start) * 1000)
                cache_get_start = time.monotonic()
                cached = cache_get(cache_key)
                cache_get_ms = int((time.monotonic() - cache_get_start) * 1000)
                _log_stage("cache_lookup")
                if cached is not None:
                    session_prepare_cache = "hit"
                    if isinstance(cached, dict):
                        payload_fingerprint = str(cached.get("payload_fingerprint") or cached.get("config_revision") or "")
                        active_config_hash = str(cached.get("active_config_hash") or cached.get("apply_config_sha256") or "")
                    return cached

                session_prepare_cache = "miss"
                create_start = time.monotonic()
                result = await run_sync(
                    vpn_service.get_existing_connection_config,
                    user,
                    vpn_service.validate_and_get_server(request_data.server_id),
                    protocol,
                    request_data.device_id,
                    request_data.fingerprint,
                )
                if isinstance(result, dict):
                    payload_fingerprint = str(result.get("payload_fingerprint") or result.get("config_revision") or "")
                    active_config_hash = str(result.get("active_config_hash") or result.get("apply_config_sha256") or "")
                create_client_ms = int((time.monotonic() - create_start) * 1000)
                _log_stage("read_existing_config")
                if isinstance(result, dict):
                    cache_set_start = time.monotonic()
                    cache_set(cache_key, result, ttl=SESSION_PREPARE_CACHE_TTL_SEC)
                    cache_set_ms = int((time.monotonic() - cache_set_start) * 1000)
                    _log_stage("cache_set")
                return result
        session_prepare_cache = "non_xray"
        return await connect_vpn(request_data, credentials, vpn_service)
    except HTTPException as e:
        log_status = int(e.status_code)
        raise
    except AppException as e:
        log_status = int(e.status_code)
        raise
    except Exception:
        log_status = 500
        raise
    finally:
        try:
            if protocol.startswith("xray_"):
                from core.metrics import metrics_registry

                metrics_registry.record_vpn_prepare_create_client_ms(
                    float(create_client_ms)
                )
        except Exception:
            pass
        try:
            emit_observability_event(
                vpn_service.db,
                event_name="VPN_CONNECT_PREPARE_FINISHED",
                severity="warn" if log_status >= 400 else "info",
                source="backend",
                user_id=None if user_id_log == "unknown" else int(user_id_log),
                server_id=request_data.server_id,
                protocol=protocol,
                stage="prepare",
                outcome="failure" if log_status >= 400 else "success",
                reason_code="HTTP_ERROR" if log_status >= 400 else None,
                config_revision=payload_fingerprint or None,
                config_hash_expected=payload_fingerprint or None,
                config_hash_actual=active_config_hash or None,
                attrs={
                    "status": log_status,
                    "elapsed_ms": int((time.monotonic() - start_ts) * 1000),
                    "cache": session_prepare_cache,
                    "request_id": req_id_log,
                    "payload_fingerprint": payload_fingerprint,
                    "active_config_hash": active_config_hash,
                },
                commit=True,
            )
            elapsed_ms = int((time.monotonic() - start_ts) * 1000)
            device_id_log = (request_data.device_id or "").strip() or None
            logger.warning(
                "[session_prepare_metric] req_id=%s user_id=%s server_id=%s device_id=%s protocol=%s "
                "status=%s elapsed_ms=%s cache=%s lock_wait_ms=%s create_client_ms=%s "
                "cache_get_ms=%s cache_set_ms=%s payload_fingerprint=%s active_config_hash=%s",
                req_id_log,
                user_id_log,
                request_data.server_id,
                device_id_log,
                protocol,
                log_status,
                elapsed_ms,
                session_prepare_cache,
                lock_wait_ms,
                create_client_ms,
                cache_get_ms,
                cache_set_ms,
                payload_fingerprint,
                active_config_hash,
            )
        except Exception:
            pass


@router.post("/session/prewarm")
async def prewarm_vpn_session(
    request_data: ConnectVPNRequest,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service),
):
    """
    Прогрев SSH к ноде: открывает соединение и возвращает его в пул процесса,
    чтобы следующий session/prepare не платил полный TCP+handshake.
    """
    try:
        user = AuthService.get_current_user(credentials.credentials, vpn_service.db)
    except Exception:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Неверный или просроченный токен",
        )

    def _warm() -> dict:
        from infrastructure.external.remote_vpn_manager import RemoteVPNManager

        rm = RemoteVPNManager()
        if not rm.ssh_manager:
            return {"success": False, "server_id": request_data.server_id, "message": "SSH unavailable"}
        server = vpn_service.validate_and_get_server(request_data.server_id)
        cfg = rm.get_ssh_config(server)
        ok = rm.ssh_manager.test_connection(
            cfg["host"],
            cfg["port"],
            cfg["username"],
            password=cfg.get("password"),
            key_path=cfg.get("key_path"),
            key_content=cfg.get("key_content"),
        )
        return {"success": bool(ok), "server_id": server.id}

    return await run_sync(_warm)


@router.post("/connect")
async def connect_vpn(
    request_data: ConnectVPNRequest,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service)
):
    """Подключение к VPN. Без device_id — единый алгоритм (один коннект на user, server, protocol)."""
    start_ts = time.monotonic()
    success = False
    user_id_log = "unknown"
    try:
        from services.auth_service import AuthService
        user = AuthService.get_current_user(credentials.credentials, vpn_service.db)
        user_id_log = user.id
        emit_observability_event(
            vpn_service.db,
            event_name="VPN_CONNECT_REQUESTED",
            severity="info",
            source="backend",
            user_id=user.id,
            server_id=request_data.server_id,
            protocol=request_data.protocol or "xray_vless",
            stage="connect",
            outcome="started",
            attrs={"device_id": request_data.device_id},
            commit=True,
        )
        logger.info(f"Запрос на подключение VPN: user_id={user.id}, device_id={request_data.device_id}, server_id={request_data.server_id}, protocol={request_data.protocol}")

        server = vpn_service.validate_and_get_server(request_data.server_id)
        protocol = request_data.protocol or "xray_vless"

        if not request_data.device_id or not request_data.device_id.strip():
            if protocol in ("graniwg", "wireguard"):
                raise HTTPException(
                    status_code=400,
                    detail="Для GraniWG требуется device_id. Зарегистрируйте устройство.",
                )
            result = await run_sync(vpn_service.get_or_create_connection, user, server, protocol)
            success = True
            return result

        device_data_connect = {
            'name': f"Device {request_data.device_id[:8]}",
            'device_id': request_data.device_id,
            'platform': 'unknown'
        }
        if request_data.fingerprint:
            device_data_connect['fingerprint'] = request_data.fingerprint
        device = vpn_service.validate_and_get_device(
            user,
            request_data.device_id,
            auto_register=True,
            device_data=device_data_connect
        )
        result = await run_sync(vpn_service.connect_device, user, device, server, protocol)
        success = True
        emit_observability_event(
            vpn_service.db,
            event_name="VPN_TUNNEL_ESTABLISHED",
            severity="info",
            source="backend",
            user_id=user.id,
            device_id=device.id,
            server_id=server.id,
            protocol=protocol,
            stage="connect",
            outcome="success",
            attrs={"ip_address": result.get("ip_address"), "client_id": result.get("client_id")},
            commit=True,
        )
        return result

    except AppException:
        raise
    except HTTPException:
        raise
    except Exception as e:
        try:
            emit_observability_event(
                vpn_service.db,
                event_name="VPN_CLIENT_CONNECTION_ERROR",
                severity="error",
                source="backend",
                user_id=None if user_id_log == "unknown" else int(user_id_log),
                server_id=request_data.server_id,
                protocol=request_data.protocol or "xray_vless",
                stage="connect",
                outcome="failure",
                reason_code="CONNECT_EXCEPTION",
                message=str(e),
                attrs={"device_id": request_data.device_id},
                commit=True,
            )
        except Exception:
            pass
        logger.error(f"Ошибка подключения к VPN: user_id={user.id if 'user' in locals() else 'unknown'}, device_id={getattr(request_data, 'device_id', None)}, error={e}", exc_info=True)
        raise HTTPException(
            status_code=400,
            detail=f"Ошибка подключения: {str(e)}"
        )
    finally:
        try:
            elapsed_ms = int((time.monotonic() - start_ts) * 1000)
            logger.info(
                f"[connect-vpn-timing] user_id={user_id_log}, server_id={request_data.server_id}, "
                f"protocol={request_data.protocol or 'xray_vless'}, elapsed_ms={elapsed_ms}, success={success}"
            )
        except Exception:
            pass

@router.post("/disconnect")
async def disconnect_vpn(
    request: Request,
    device_id: Optional[str] = None,
    force: Optional[bool] = None,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service)
):
    """Отключение от VPN
    
    Args:
        request_data.force: Принудительное отключение (пропускает удаление пира/клиента на сервере)
                           Используется для очистки состояния при ошибках синхронизации
    """
    try:
        # Получаем пользователя из токена
        from services.auth_service import AuthService
        user = AuthService.get_current_user(credentials.credentials, vpn_service.db)

        body_device_id = None
        body_force = None
        body_client_id = None
        try:
            raw_body = await request.body()
            if raw_body:
                try:
                    payload = json.loads(raw_body)
                except Exception:
                    payload = None
                if isinstance(payload, dict):
                    body_device_id = payload.get("device_id")
                    body_force = payload.get("force")
                    body_client_id = payload.get("client_id")
        except Exception:
            payload = None

        effective_force = (
            body_force if body_force is not None
            else (force if force is not None else False)
        )
        resolved_device_id = body_device_id or device_id

        if resolved_device_id:
            logger.info(f"Запрос на отключение VPN: user_id={user.id}, device_id={resolved_device_id}, force={effective_force}")
            device = vpn_service.validate_and_get_device(user, resolved_device_id)
            result = await run_sync(vpn_service.disconnect_device, user, device, effective_force)
            emit_observability_event(
                vpn_service.db,
                event_name="VPN_TUNNEL_CLOSED",
                severity="info",
                source="backend",
                user_id=user.id,
                device_id=device.id,
                server_id=device.current_server_id,
                protocol=getattr(device, "vpn_protocol", None),
                stage="disconnect",
                outcome="success",
                attrs={"force": bool(effective_force)},
                commit=True,
            )
            return result
        if body_client_id:
            logger.info(f"Запрос на отключение VPN по client_id: user_id={user.id}, client_id={body_client_id}, force={effective_force}")
            return await run_sync(vpn_service.disconnect_by_client_id, user, body_client_id, effective_force)
        raise HTTPException(status_code=400, detail="Укажите device_id или client_id")
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Неожиданная ошибка при отключении: {e}", exc_info=True)
        raise HTTPException(status_code=400, detail=f"Ошибка отключения: {str(e)}")

@router.get("/status", response_model=VPNStatus)
async def get_vpn_status(
    device_id: str,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service)
):
    """Получение статуса VPN подключения"""
    try:
        # Получаем пользователя из токена
        from services.auth_service import AuthService
        user = AuthService.get_current_user(credentials.credentials, vpn_service.db)
        logger.debug(f"Запрос статуса VPN: user_id={user.id}, device_id={device_id}")
        
        # Получаем устройство
        device = vpn_service.validate_and_get_device(user, device_id)
        
        # Получаем статус (sync SSH/subprocess — run in thread pool)
        vpn_status = await run_sync(vpn_service.get_device_status, user, device)
        return VPNStatus(**vpn_status)
        
    except HTTPException as exc:
        if exc.status_code == status.HTTP_404_NOT_FOUND:
            # Не блокируем клиента, если устройство еще не зарегистрировано
            return VPNStatus(connected=False)
        raise
    except Exception as e:
        logger.error(f"Неожиданная ошибка при получении статуса: {e}", exc_info=True)
        raise HTTPException(status_code=400, detail=f"Ошибка получения статуса: {str(e)}")

def _generate_flag_url(country: str) -> str:
    """
    Генерирует URL флага страны на основе названия страны.
    Использует сервис flagcdn.com для получения флагов.
    """
    from core.country_mapping import generate_flag_url
    return generate_flag_url(country)


DEFAULT_XRAY_PORT = 4443
DEFAULT_XRAY_CONFIG_PATH = "/etc/xray/config.json"


def _has_reality_fields(server: Server) -> bool:
    return any([
        server.reality_public_key,
        server.reality_private_key,
        server.reality_short_id,
        server.reality_dest,
        server.reality_sni,
        server.reality_server_name,
    ])


def _needs_xray_backfill(servers: List[Server]) -> bool:
    for server in servers:
        if server.xray_port is None or not server.xray_config_path:
            return True
        if server.reality_enabled is None:
            return True
        if not server.reality_enabled and _has_reality_fields(server):
            return True
    return False


def _ensure_xray_defaults(db: Session, servers: List[Server]) -> None:
    updated = 0
    for server in servers:
        changed = False

        if server.xray_port is None:
            server.xray_port = DEFAULT_XRAY_PORT
            changed = True

        if not server.xray_config_path:
            server.xray_config_path = DEFAULT_XRAY_CONFIG_PATH
            changed = True

        if server.reality_enabled is None or (not server.reality_enabled and _has_reality_fields(server)):
            server.reality_enabled = _has_reality_fields(server)
            changed = True

        if changed:
            updated += 1

    if updated:
        try:
            db.commit()
            logger.info(f"Xray defaults backfilled for {updated} servers")
        except Exception as exc:
            db.rollback()
            logger.warning(f"Failed to backfill Xray defaults: {exc}")


@router.get("/servers", response_model=List[ServerInfo])
async def get_servers(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
):
    """Получение списка доступных серверов"""
    try:
        # Получаем пользователя из токена
        user = AuthService.get_current_user(credentials.credentials, db)
        logger.debug(f"Запрос списка серверов: user_id={user.id}")
        
        # Кэширование списка серверов
        from core.cache import cache_get, cache_set
        cache_key = "cache:servers:list"
        cached_servers = cache_get(cache_key)
        
        if cached_servers:
            if _needs_xray_backfill(cached_servers):
                servers = db.query(Server).filter(Server.is_active == True).all()
                _ensure_xray_defaults(db, servers)
                cache_set(cache_key, servers, ttl=300)  # Кэш на 5 минут
                logger.debug(f"Серверы перезагружены из БД: count={len(servers)}")
            else:
                servers = cached_servers
                logger.debug(f"Серверы получены из кэша: count={len(servers)}")
        else:
            # Оптимизированный запрос: загружаем только активные серверы без relationships
            servers = db.query(Server).filter(Server.is_active == True).all()
            _ensure_xray_defaults(db, servers)
            # Обновляем кэш с актуальными данными
            cache_set(cache_key, servers, ttl=300)  # Кэш на 5 минут
            logger.debug(f"Серверы загружены из БД и закэшированы: count={len(servers)}")
        
        # Глобально включённые протоколы из таблицы protocols (управление из админки)
        enabled_protocol_codes: set = set()
        try:
            enabled_rows = db.query(Protocol.code).filter(Protocol.status == "enabled").all()
            enabled_protocol_codes = {row.code for row in enabled_rows}
        except Exception as e:
            logger.warning(f"Не удалось загрузить протоколы из БД, используем все xray: {e}")
        if not enabled_protocol_codes:
            enabled_protocol_codes = {
                "xray_vless",
                "xray_vmess",
                "xray_vless_ws_tls",
                "xray_vless_grpc_tls",
            }
        # Антикризисный rollout: WS/gRPC профили доступны даже до обновления таблицы protocols.
        enabled_protocol_codes.update({"xray_vless_ws_tls", "xray_vless_grpc_tls"})

        result = []
        for server in servers:
            if getattr(server, "health_status", None) in {"healthy", "warning", "error"}:
                health_status = server.health_status
            else:
                health_status = "unknown"
            
            # Собираем протоколы сервера
            try:
                if hasattr(server, 'get_supported_protocols'):
                    supported_protocols = server.get_supported_protocols()
                else:
                    supported_protocols = getattr(server, 'supported_protocols', None)
            except Exception as e:
                logger.warning(f"Ошибка получения supported_protocols для сервера {server.id}: {e}")
                supported_protocols = None
            
            if supported_protocols is None:
                supported_protocols = []
            elif isinstance(supported_protocols, str):
                import json
                try:
                    supported_protocols = json.loads(supported_protocols)
                except Exception:
                    supported_protocols = [supported_protocols] if supported_protocols else []
            elif not isinstance(supported_protocols, list):
                supported_protocols = []
            if not isinstance(supported_protocols, list) or not all(isinstance(p, str) for p in supported_protocols):
                supported_protocols = []
            protocols_set = set(supported_protocols)
            effective_reality_enabled = bool(getattr(server, "reality_enabled", False) or _has_reality_fields(server))
            has_xray = bool(
                getattr(server, "xray_port", None) or
                getattr(server, "xray_config_path", None) or
                effective_reality_enabled
            )
            if has_xray:
                protocols_set.add("xray_vless")
                protocols_set.add("xray_vmess")
                protocols_set.add("xray_vless_ws_tls")
                protocols_set.add("xray_vless_grpc_tls")
            if effective_reality_enabled:
                protocols_set.add("xray_reality")
            allowed_protocols = {
                "xray_vless",
                "xray_vmess",
                "xray_reality",
                "xray_vless_ws_tls",
                "xray_vless_grpc_tls",
            }
            # Пересекаем с глобально включёнными протоколами
            supported_protocols = sorted(
                [p for p in protocols_set if p in allowed_protocols and p in enabled_protocol_codes]
            )
            if not supported_protocols:
                # Сервер без доступных протоколов — пропускаем
                logger.info(f"Сервер {server.id} ({server.name}) пропущен: нет включённых протоколов")
                continue
            
            # Генерируем URL флага на основе страны
            flag_url = _generate_flag_url(server.country)
            
            result.append(ServerInfo(
                id=server.id,
                name=server.name,
                country=server.country,
                city=server.city,
                ip_address=server.ip_address,
                port=server.wireguard_port or WIREGUARD_DEFAULT_PORT,  # Используем wireguard_port вместо port
                current_users=server.current_users or 0,
                max_users=server.max_users or DEFAULT_MAX_USERS_PER_SERVER,
                is_active=server.is_active,
                health_status=health_status,
                supported_protocols=supported_protocols,
                wireguard_port=server.wireguard_port or WIREGUARD_DEFAULT_PORT,
                wireguard_public_key=server.wireguard_public_key,
                flag_url=flag_url,
                ping_ms=getattr(server, "ping_ms", None),
                xray_port=getattr(server, "xray_port", None),
            ))
        
        logger.info(f"Список серверов возвращен: user_id={user.id}, count={len(result)}")
        return result
        
    except Exception as e:
        import traceback
        error_trace = traceback.format_exc()
        user_id = user.id if 'user' in locals() else 'unknown'
        error_msg = str(e) if str(e) else repr(e)
        logger.error(f"Ошибка получения списка серверов: user_id={user_id}, error={error_msg}")
        logger.error(f"Stack trace:\n{error_trace}")
        raise HTTPException(status_code=400, detail=f"Ошибка получения списка серверов: {error_msg}")

@router.get("/devices")
async def get_user_devices(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
):
    """Получение списка устройств пользователя"""
    t0 = time.monotonic()
    req_id = get_request_id()
    try:
        user = AuthService.get_current_user(credentials.credentials, db)
        device_manager = DeviceManager(db)
        devices = device_manager.get_user_devices(user)
        logger.info(
            "[vpn_devices] req_id=%s user_id=%s count=%s elapsed_ms=%s",
            req_id,
            user.id,
            len(devices) if isinstance(devices, list) else -1,
            int((time.monotonic() - t0) * 1000),
        )
        return devices
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


class DeviceDeactivateRequest(BaseModel):
    device_id: str


@router.post("/device/deactivate")
async def deactivate_device(
    request_data: DeviceDeactivateRequest,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service)
):
    """Деактивация устройства пользователя"""
    try:
        user = AuthService.get_current_user(credentials.credentials, vpn_service.db)
        device = vpn_service.validate_and_get_device(user, request_data.device_id)
        result = vpn_service.disconnect_device(user, device, force=False)
        return {
            "message": result.get("message", "Устройство отключено"),
            "device_id": device.id,
            "force": result.get("force", False)
        }
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Ошибка деактивации устройства: {e}", exc_info=True)
        raise HTTPException(status_code=400, detail=f"Ошибка деактивации устройства: {str(e)}")

@router.get("/stats")
async def get_connection_stats(
    days: int = 7,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service)
):
    """Получение статистики подключений пользователя"""
    try:
        user = AuthService.get_current_user(credentials.credentials, vpn_service.db)
        return vpn_service.get_connection_stats(user, days)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@router.get("/system/stats")
async def get_system_stats(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service)
):
    """Получение системной статистики (только для админов)"""
    try:
        try:
            get_current_admin_user(credentials, db)
        except HTTPException:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Доступ запрещен. Только администраторы могут просматривать системную статистику."
            )
        return vpn_service.get_system_stats()
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@router.post("/system/cleanup")
async def cleanup_inactive_connections(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service)
):
    """Очистка неактивных подключений (только для админов)"""
    try:
        try:
            get_current_admin_user(credentials, db)
        except HTTPException:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Доступ запрещен. Только администраторы могут очищать неактивные подключения."
            )
        cleaned_count = vpn_service.cleanup_inactive_connections()
        return {
            "message": f"Очищено {cleaned_count} неактивных подключений",
            "cleaned_count": cleaned_count
        }
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@router.get("/server/{server_id}/logs")
async def get_server_logs(
    server_id: int,
    log_type: str = "access",
    protocol: str = "xray",
    lines: int = 100,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db)
):
    """
    Получение логов с VPN сервера (только для админов)
    
    Args:
        server_id: ID сервера
        log_type: Тип лога - "access", "error", или "journalctl" (для XRay)
        protocol: Протокол - "xray" или "wireguard"
        lines: Количество строк для получения (максимум 1000)
        credentials: Токен авторизации
        db: Сессия БД
    """
    try:
        # Проверка прав администратора
        try:
            admin_user = get_current_admin_user(credentials, db)
        except HTTPException:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Доступ запрещен. Только администраторы могут просматривать логи серверов."
            )
        
        # Ограничиваем количество строк
        lines = min(lines, 1000)
        
        # Получаем сервер
        server = db.query(Server).filter(Server.id == server_id).first()
        if not server:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"Сервер с ID {server_id} не найден"
            )
        
        # Импортируем RemoteVPNManager
        from services.remote_vpn_manager import RemoteVPNManager
        remote_manager = RemoteVPNManager()
        
        if not remote_manager.ssh_manager:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="SSH недоступен для получения логов"
            )
        
        # Получаем логи в зависимости от протокола
        if protocol.lower() == "wireguard":
            result = remote_manager.get_wireguard_logs(server, lines=lines)
        else:
            # По умолчанию XRay
            result = remote_manager.get_xray_logs(server, log_type=log_type, lines=lines)
        
        if not result.get('success'):
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=f"Ошибка получения логов: {result.get('error', 'Неизвестная ошибка')}"
            )
        
        return {
            "server_id": server_id,
            "server_name": server.name,
            "protocol": protocol,
            "log_type": result.get('log_type'),
            "lines_count": result.get('lines_count', 0),
            "logs": result.get('logs', [])
        }
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Ошибка получения логов сервера {server_id}: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Ошибка получения логов: {str(e)}")

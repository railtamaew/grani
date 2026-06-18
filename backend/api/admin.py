from fastapi import APIRouter, Depends, HTTPException, status, Request
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.orm import Session, joinedload
from datetime import datetime, timedelta
from typing import List, Optional
from sqlalchemy import func, or_, and_

from core.config import settings
from core.database import get_db
from core.cache import invalidate_user_cache
from core.rbac import get_current_admin_user, require_admin_or_owner, require_support_or_above, require_role, require_owner, UserRole
from models.user import User, Device
from models.subscription import Subscription, Plan
from models.server import Server, ConnectionLog
from models.payment import Payment
from models.client_log import ClientLog
from models.edge_node_assignment import EdgeNodeAssignment
from models.telemetry import TelemetryEvent
from models.auth_code import AuthCode
from services.auth_service import AuthService
from services.xray_manager import XrayManager
from core.dependencies import get_vpn_operations_service
try:
    from application.services.vpn_operations_service import VPNOperationsService
except ImportError:
    from services.vpn_operations_service import VPNOperationsService
from services.server_load_calculator import ServerLoadCalculator
from services.provider_monitor import ProviderMonitor
from services.protocol_analyzer import ProtocolAnalyzer
from services.server_selector import ServerSelector
from middleware.audit_middleware import create_audit_log
from pydantic import BaseModel, Field
import json
import uuid

router = APIRouter()
security = HTTPBearer()

def _parse_iso_datetime(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        try:
            return datetime.strptime(value, "%Y-%m-%d")
        except ValueError:
            return None

# Pydantic модели
class UserInfo(BaseModel):
    id: int
    email: str
    is_active: bool
    is_verified: bool
    created_at: datetime
    subscription_status: Optional[str] = None
    subscription_end_date: Optional[datetime] = None
    devices_count: int = 0
    country: Optional[str] = None
    auth_provider: Optional[str] = None
    last_seen_at: Optional[datetime] = None

class UsersResponse(BaseModel):
    users: List[UserInfo]
    total: int
    page: int
    limit: int

class DeviceInfo(BaseModel):
    id: int
    user_id: int
    user_email: Optional[str] = None
    device_id: str
    device_name: Optional[str] = None
    platform: Optional[str] = None
    model: Optional[str] = None
    app_version: Optional[str] = None
    is_active: bool
    last_connected: Optional[datetime] = None
    last_ip: Optional[str] = None
    created_at: datetime

class DevicesResponse(BaseModel):
    devices: List[DeviceInfo]
    total: int
    page: int
    limit: int

class BulkDevicesRequest(BaseModel):
    device_ids: List[int]

class TrialInfo(BaseModel):
    user_id: int
    email: str
    status: str
    trial_active: bool
    trial_started_at: Optional[datetime] = None
    trial_seconds_left: int
    trial_ends_at: Optional[datetime] = None

class TrialsResponse(BaseModel):
    trials: List[TrialInfo]
    total: int
    page: int
    limit: int


class TrialSetRequest(BaseModel):
    duration_minutes: int = Field(default=24 * 60, ge=1, le=60 * 24 * 30)

class ServerInfo(BaseModel):
    id: int
    name: str
    ip_address: str
    country: str
    city: Optional[str] = None
    is_active: bool
    current_users: int
    max_users: int
    health_status: str
    status: Optional[str] = None
    port: Optional[int] = None
    load_percentage: Optional[float] = None
    bandwidth_used_mbps: Optional[float] = None
    bandwidth_limit_mbps: Optional[float] = None
    ping_ms: Optional[float] = None
    supported_protocols: Optional[List[str]] = None
    provider: Optional[str] = None
    provider_region: Optional[str] = None
    uptime_percentage: Optional[float] = None
    last_health_check: Optional[datetime] = None
    wireguard_port: Optional[int] = None
    xray_port: Optional[int] = None
    openvpn_port: Optional[int] = None


class ServersListResponse(BaseModel):
    servers: List[ServerInfo]
    total: int
    page: int
    limit: int


def _build_server_info(server: Server, health: dict, supported_protocols: List[str]) -> ServerInfo:
    return ServerInfo(
        id=server.id,
        name=server.name,
        ip_address=server.ip_address,
        country=server.country,
        city=server.city,
        is_active=server.is_active,
        current_users=server.current_users,
        max_users=server.max_users,
        health_status=health.get("wireguard_status") or getattr(server, 'health_status', "unknown"),
        status=getattr(server, 'status', None),
        port=server.wireguard_port,
        load_percentage=getattr(server, 'load_percentage', None),
        bandwidth_used_mbps=getattr(server, 'bandwidth_used_mbps', None),
        bandwidth_limit_mbps=getattr(server, 'bandwidth_limit_mbps', None),
        ping_ms=getattr(server, 'ping_ms', None),
        supported_protocols=supported_protocols,
        provider=getattr(server, 'provider', None),
        provider_region=getattr(server, 'provider_region', None),
        uptime_percentage=getattr(server, 'uptime_percentage', None),
        last_health_check=getattr(server, 'last_health_check', None),
        wireguard_port=server.wireguard_port,
        xray_port=getattr(server, 'xray_port', None),
        openvpn_port=getattr(server, 'openvpn_port', None),
        ssh_host=getattr(server, 'ssh_host', None),
        ssh_port=getattr(server, 'ssh_port', None),
        ssh_user=getattr(server, 'ssh_user', None),
        has_ssh_key=bool(getattr(server, 'ssh_key_path', None) or getattr(server, 'ssh_key_content', None))
    )


def _server_protocols(server: Server) -> List[str]:
    raw_protocols = getattr(server, 'supported_protocols', None)
    protocols = raw_protocols if isinstance(raw_protocols, list) else []
    if not protocols:
        try:
            protocols = server.get_supported_protocols() if hasattr(server, 'get_supported_protocols') else []
        except Exception:
            protocols = []
    if not protocols:
        protocols = ["graniwg"] if getattr(server, 'graniwg_enabled', False) else ["xray_vless"]
    return protocols


def _check_server_health(server: Server) -> dict:
    """Проверка состояния сервера через remote-aware XrayManager."""
    if not getattr(server, 'is_active', False):
        return {"wireguard_status": "maintenance", "xray_status": "skipped"}

    protocols = set(_server_protocols(server))
    has_graniwg = bool(getattr(server, 'graniwg_enabled', False)) or "graniwg" in protocols
    has_xray = any(str(p).startswith("xray_") for p in protocols)
    if has_graniwg and not has_xray:
        return {"wireguard_status": getattr(server, 'status', None) or "online", "xray_status": "not_applicable"}

    try:
        xray_health = XrayManager(server).check_server_health(server)
        status = xray_health.get("status")
        if status == "healthy":
            wireguard_status = "running"
        elif status in {"error", "unhealthy"}:
            wireguard_status = "error"
        else:
            wireguard_status = status or "unknown"
        return {
            "wireguard_status": wireguard_status,
            "xray_status": xray_health.get("status", "unknown"),
        }
    except Exception:
        return {"wireguard_status": "unknown", "xray_status": "unknown"}

class PlanInfo(BaseModel):
    id: int
    name: str
    description: Optional[str]
    price: float
    duration_days: int
    max_speed_mbps: int
    max_devices: int
    is_active: bool

class DashboardStats(BaseModel):
    total_users: int
    active_subscriptions: int
    total_revenue: float
    active_connections: int
    server_count: int

class SubscriptionInfo(BaseModel):
    id: int
    user_id: int
    user_email: str
    plan_id: int
    plan_name: Optional[str]
    status: Optional[str]
    start_date: Optional[datetime]
    end_date: Optional[datetime]
    auto_renew: bool
    source: Optional[str]
    external_id: Optional[str]

class SubscriptionsResponse(BaseModel):
    subscriptions: List[SubscriptionInfo]
    total: int
    page: int
    limit: int


class CreateSubscriptionRequest(BaseModel):
    """Тело запроса для ручного создания подписки (админка шлёт JSON body)."""
    plan_id: int
    end_date: datetime
    reason: str = ""


class PaymentInfo(BaseModel):
    id: int
    user_id: int
    user_email: str
    plan_id: Optional[int]
    plan_name: Optional[str]
    amount: float
    currency: str
    payment_method: str
    status: str
    created_at: datetime
    updated_at: datetime
    subscription_id: Optional[int] = None

class PaymentsResponse(BaseModel):
    payments: List[PaymentInfo]
    total: int
    page: int
    limit: int

class ConnectionLogsResponse(BaseModel):
    logs: List[dict]
    total: int
    page: int
    limit: int

class ClientLogsResponse(BaseModel):
    logs: List[dict]
    total: int
    page: int
    limit: int

class SupportDiagnosticsResponse(BaseModel):
    reports: List[dict]
    total: int
    page: int
    limit: int

# Используем новый RBAC из core.rbac
require_admin = get_current_admin_user

# Пользователи
@router.get("/users", response_model=UsersResponse)
async def get_users(
    page: int = 1,
    limit: int = 20,
    country: Optional[str] = None,
    has_subscription: Optional[bool] = None,
    auth_provider: Optional[str] = None,
    has_errors: Optional[bool] = None,
    search: Optional[str] = None,
    admin_user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Получение списка пользователей с фильтрами"""
    query = db.query(User)
    
    # Фильтр по стране
    if country:
        query = query.filter(User.country == country)
    
    # Фильтр по auth_provider
    if auth_provider:
        query = query.filter(User.auth_provider == auth_provider)
    
    # Поиск по email
    if search:
        query = query.filter(User.email.ilike(f"%{search}%"))
    
    # Подсчет общего количества ДО применения фильтров has_subscription и has_errors
    # (эти фильтры применяются после загрузки пользователей)
    base_query = query
    total_count = base_query.count()
    
    # Применяем стабильную сортировку до пагинации, чтобы новые пользователи
    # не пропадали с первой страницы из-за неопределенного порядка PostgreSQL.
    skip = (page - 1) * limit
    users = query.order_by(User.id.desc()).offset(skip).limit(limit).all()
    
    result = []
    for user in users:
        # Получаем активную подписку
        subscription = db.query(Subscription).filter(
            Subscription.user_id == user.id,
            Subscription.status == "active",
            Subscription.end_date > datetime.utcnow()
        ).first()
        
        # Фильтр по подписке
        if has_subscription is not None:
            if has_subscription and not subscription:
                continue
            if not has_subscription and subscription:
                continue
        
        # Фильтр по наличию ошибок (нужно проверить через телеметрию)
        if has_errors is not None:
            from models.telemetry import TelemetryEvent
            error_count = db.query(TelemetryEvent).filter(
                TelemetryEvent.user_id == user.id,
                TelemetryEvent.error_code.isnot(None)
            ).count()
            if has_errors and error_count == 0:
                continue
            if not has_errors and error_count > 0:
                continue
        
        # Подсчет устройств
        devices_count = db.query(Device).filter(Device.user_id == user.id).count()
        
        result.append(UserInfo(
            id=user.id,
            email=user.email,
            is_active=user.is_active,
            is_verified=user.is_verified,
            created_at=user.created_at,
            subscription_status=subscription.status if subscription else None,
            subscription_end_date=subscription.end_date if subscription else None,
            devices_count=devices_count,
            country=user.country,
            auth_provider=user.auth_provider,
            last_seen_at=user.last_seen_at
        ))
    
    # Если применены фильтры has_subscription или has_errors, нужно пересчитать total
    # Для простоты используем количество отфильтрованных результатов
    if has_subscription is not None or has_errors is not None:
        total_count = len(result)
    
    return UsersResponse(
        users=result,
        total=total_count,
        page=page,
        limit=limit
    )

@router.put("/users/{user_id}/block")
async def block_user(
    user_id: int,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service)
):
    """Блокировка пользователя. Все активные VPN-подключения пользователя отключаются на серверах."""
    target_user = db.query(User).filter(User.id == user_id).first()
    if not target_user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Пользователь не найден"
        )
    # Отключаем все устройства пользователя от VPN (удаляем пиры/клиентов на серверах)
    devices = db.query(Device).filter(Device.user_id == user_id, Device.is_active == True).all()
    for device in devices:
        try:
            vpn_service.disconnect_device(target_user, device, force=False)
        except Exception:
            # Пытаемся принудительно отключить локальное состояние
            try:
                vpn_service.disconnect_device(target_user, device, force=True)
            except Exception:
                pass
    target_user.is_active = False
    db.commit()
    return {"message": "Пользователь заблокирован"}

@router.put("/users/{user_id}/unblock")
async def unblock_user(
    user_id: int,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Разблокировка пользователя"""
    target_user = db.query(User).filter(User.id == user_id).first()
    if not target_user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Пользователь не найден"
        )
    
    target_user.is_active = True
    db.commit()
    
    return {"message": "Пользователь разблокирован"}

@router.get("/users/{user_id}")
async def get_user_detail(
    user_id: int,
    admin_user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Детальная информация о пользователе"""
    target_user = db.query(User).filter(User.id == user_id).first()
    if not target_user:
        raise HTTPException(status_code=404, detail="Пользователь не найден")
    
    # Активная подписка
    subscription = db.query(Subscription).filter(
        Subscription.user_id == user_id,
        Subscription.status == "active",
        Subscription.end_date > datetime.utcnow()
    ).first()
    
    # Устройства
    devices = db.query(Device).filter(Device.user_id == user_id).all()
    
    # История подписок
    all_subscriptions = db.query(Subscription).filter(Subscription.user_id == user_id).order_by(Subscription.created_at.desc()).all()
    
    return {
        "id": target_user.id,
        "email": target_user.email,
        "auth_provider": target_user.auth_provider,
        "country": target_user.country,
        "is_active": target_user.is_active,
        "is_verified": target_user.is_verified,
        "created_at": target_user.created_at.isoformat() if target_user.created_at else None,
        "last_seen_at": target_user.last_seen_at.isoformat() if target_user.last_seen_at else None,
        "notes": target_user.notes,
        "current_subscription": {
            "id": subscription.id,
            "plan_id": subscription.plan_id,
            "status": subscription.status,
            "start_date": subscription.start_date.isoformat() if subscription.start_date else None,
            "end_date": subscription.end_date.isoformat() if subscription.end_date else None
        } if subscription else None,
        "devices_count": len(devices),
        "devices": [
            {
                "id": d.id,
                "device_id": d.device_id,
                "device_name": d.device_name,
                "platform": d.platform,
                "model": d.model,
                "os_version": d.os_version,
                "app_version": d.app_version,
                "last_ip": d.last_ip,
                "last_country": d.last_country,
                "is_active": d.is_active,
                "last_connected": d.last_connected.isoformat() if d.last_connected else None,
                "created_at": d.created_at.isoformat() if d.created_at else None
            }
            for d in devices
        ],
        "subscriptions": [
            {
                "id": s.id,
                "plan_id": s.plan_id,
                "status": s.status,
                "source": s.source,
                "start_date": s.start_date.isoformat() if s.start_date else None,
                "end_date": s.end_date.isoformat() if s.end_date else None,
                "auto_renew": s.auto_renew
            }
            for s in all_subscriptions
        ]
    }

@router.patch("/users/{user_id}")
async def update_user(
    user_id: int,
    email: Optional[str] = None,
    notes: Optional[str] = None,
    admin_user: User = Depends(require_admin_or_owner),
    request: Request = None,
    db: Session = Depends(get_db)
):
    """Обновление пользователя (email, notes)"""
    target_user = db.query(User).filter(User.id == user_id).first()
    if not target_user:
        raise HTTPException(status_code=404, detail="Пользователь не найден")
    
    old_value = {"email": target_user.email, "notes": target_user.notes}
    
    if email is not None:
        # Проверка на уникальность email
        existing = db.query(User).filter(User.email == email.lower(), User.id != user_id).first()
        if existing:
            raise HTTPException(status_code=400, detail="Email уже используется")
        target_user.email = email.lower()
    
    if notes is not None:
        target_user.notes = notes
    
    target_user.updated_at = datetime.utcnow()
    db.commit()
    
    # Audit log
    create_audit_log(
        db, admin_user, "update", "user", user_id,
        old_value=old_value,
        new_value={"email": target_user.email, "notes": target_user.notes},
        ip_address=request.client.host if request and request.client else None,
        user_agent=request.headers.get("User-Agent") if request else None
    )
    
    return {"message": "Пользователь обновлен"}

@router.post("/users/{user_id}/subscription")
async def create_manual_subscription(
    user_id: int,
    body: CreateSubscriptionRequest,
    admin_user: User = Depends(require_admin_or_owner),
    request: Request = None,
    db: Session = Depends(get_db)
):
    """Ручное создание/продление подписки. Админка передаёт plan_id, end_date, reason в JSON body."""
    target_user = db.query(User).filter(User.id == user_id).first()
    if not target_user:
        raise HTTPException(status_code=404, detail="Пользователь не найден")
    
    plan = db.query(Plan).filter(Plan.id == body.plan_id).first()
    if not plan:
        raise HTTPException(status_code=404, detail="Тариф не найден")
    
    # Деактивируем старые активные подписки
    db.query(Subscription).filter(
        Subscription.user_id == user_id,
        Subscription.status == "active"
    ).update({"status": "expired"})
    
    # Создаем новую подписку
    subscription = Subscription(
        user_id=user_id,
        plan_id=body.plan_id,
        status="active",
        start_date=datetime.utcnow(),
        end_date=body.end_date,
        source="manual",
        auto_renew=False
    )
    db.add(subscription)
    db.commit()
    invalidate_user_cache(user_id)

    # Уведомление пользователю о созданной подписке
    try:
        from services.notification_service import notify_subscription_created_manually
        end_str = body.end_date.strftime("%d.%m.%Y")
        notify_subscription_created_manually(target_user, plan.name, end_str)
    except Exception:
        pass  # не прерываем ответ при ошибке отправки письма

    # Audit log
    create_audit_log(
        db, admin_user, "create", "subscription", subscription.id,
        old_value=None,
        new_value={"user_id": user_id, "plan_id": body.plan_id, "end_date": body.end_date.isoformat(), "reason": body.reason},
        ip_address=request.client.host if request and request.client else None,
        user_agent=request.headers.get("User-Agent") if request else None
    )
    
    return {"message": "Подписка создана", "subscription_id": subscription.id}

@router.post("/users/{user_id}/trial")
async def set_trial(
    user_id: int,
    payload: TrialSetRequest,
    admin_user: User = Depends(require_admin_or_owner),
    db: Session = Depends(get_db)
):
    """Установка trial на указанное количество минут."""
    target_user = db.query(User).filter(User.id == user_id).first()
    if not target_user:
        raise HTTPException(status_code=404, detail="Пользователь не найден")

    duration_minutes = int(payload.duration_minutes)
    target_user.trial_active = True
    target_user.trial_seconds_left = duration_minutes * 60
    target_user.trial_started_at = datetime.utcnow()
    db.commit()
    invalidate_user_cache(user_id)

    try:
        from services.notification_service import notify_trial_activated
        notify_trial_activated(target_user, duration_minutes)
    except Exception:
        pass

    return {"message": f"Trial установлен на {duration_minutes} минут"}

@router.post("/users/{user_id}/devices/reset")
async def reset_user_devices(
    user_id: int,
    admin_user: User = Depends(require_admin_or_owner),
    db: Session = Depends(get_db)
):
    """Сброс всех устройств пользователя (logout all)"""
    db.query(Device).filter(Device.user_id == user_id).update({"is_active": False})
    db.commit()
    
    return {"message": "Все устройства сброшены"}

@router.delete("/devices/{device_id}")
async def delete_device(
    device_id: int,
    admin_user: User = Depends(require_admin_or_owner),
    db: Session = Depends(get_db)
):
    """Удаление конкретного устройства"""
    device = db.query(Device).filter(Device.id == device_id).first()
    if not device:
        raise HTTPException(status_code=404, detail="Устройство не найдено")

    from sqlalchemy.exc import IntegrityError
    try:
        # Фаза 1: удаляем/обнуляем связанные записи и коммитим, чтобы FK не мешали
        db.query(ConnectionLog).filter(ConnectionLog.device_id == device_id).delete(synchronize_session=False)
        db.query(ClientLog).filter(ClientLog.device_id == device_id).delete(synchronize_session=False)
        db.query(TelemetryEvent).filter(TelemetryEvent.device_id == device_id).update(
            {"device_id": None}, synchronize_session=False
        )
        db.commit()
        # Фаза 2: удаляем само устройство (по id, т.к. после commit объект device уже detached)
        db.query(Device).filter(Device.id == device_id).delete(synchronize_session=False)
        db.commit()
    except IntegrityError as e:
        db.rollback()
        orig = getattr(e, "orig", None)
        msg = str(orig.args[0]) if orig and getattr(orig, "args", None) else str(e)
        raise HTTPException(status_code=400, detail=f"Невозможно удалить: связанные данные. {msg}")
    except Exception as e:
        db.rollback()
        raise HTTPException(status_code=500, detail=str(e))

    return {"message": "Устройство удалено"}

@router.post("/devices/bulk-disable")
async def bulk_disable_devices(
    payload: BulkDevicesRequest,
    admin_user: User = Depends(require_admin_or_owner),
    db: Session = Depends(get_db)
):
    """Массовая деактивация устройств"""
    if not payload.device_ids:
        raise HTTPException(status_code=400, detail="Список устройств пуст")

    updated = db.query(Device).filter(Device.id.in_(payload.device_ids)).update(
        {"is_active": False},
        synchronize_session=False
    )
    db.commit()

    return {"updated": updated}

@router.post("/devices/bulk-delete")
async def bulk_delete_devices(
    payload: BulkDevicesRequest,
    admin_user: User = Depends(require_admin_or_owner),
    db: Session = Depends(get_db)
):
    """Массовое удаление устройств"""
    if not payload.device_ids:
        raise HTTPException(status_code=400, detail="Список устройств пуст")

    from sqlalchemy.exc import IntegrityError
    device_ids = list(payload.device_ids)
    try:
        # Фаза 1: удаляем/обнуляем связанные записи и коммитим
        db.query(ConnectionLog).filter(ConnectionLog.device_id.in_(device_ids)).delete(
            synchronize_session=False
        )
        db.query(ClientLog).filter(ClientLog.device_id.in_(device_ids)).delete(
            synchronize_session=False
        )
        db.query(TelemetryEvent).filter(TelemetryEvent.device_id.in_(device_ids)).update(
            {"device_id": None}, synchronize_session=False
        )
        db.commit()
        # Фаза 2: удаляем устройства
        deleted = db.query(Device).filter(Device.id.in_(device_ids)).delete(
            synchronize_session=False
        )
        db.commit()
    except IntegrityError as e:
        db.rollback()
        orig = getattr(e, "orig", None)
        msg = str(orig.args[0]) if orig and getattr(orig, "args", None) else str(e)
        raise HTTPException(status_code=400, detail=f"Невозможно удалить: связанные данные. {msg}")
    except Exception as e:
        db.rollback()
        raise HTTPException(status_code=500, detail=str(e))

    return {"deleted": deleted}

@router.delete("/users/{user_id}")
async def delete_user(
    user_id: int,
    reason: str,
    admin_user: User = Depends(require_owner),
    request: Request = None,
    db: Session = Depends(get_db),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service)
):
    """Soft delete пользователя. Все активные VPN-подключения отключаются на серверах."""
    target_user = db.query(User).filter(User.id == user_id).first()
    if not target_user:
        raise HTTPException(status_code=404, detail="Пользователь не найден")
    # Отключаем все устройства пользователя от VPN (удаляем пиры/клиентов на серверах)
    devices = db.query(Device).filter(Device.user_id == user_id, Device.is_active == True).all()
    for device in devices:
        try:
            vpn_service.disconnect_device(target_user, device, force=False)
        except Exception:
            try:
                vpn_service.disconnect_device(target_user, device, force=True)
            except Exception:
                pass
    target_user.is_active = False
    target_user.notes = f"{target_user.notes or ''}\n[DELETED: {datetime.utcnow().isoformat()}] Reason: {reason}".strip()
    db.commit()
    # Audit log
    create_audit_log(
        db, admin_user, "delete", "user", user_id,
        old_value={"email": target_user.email, "is_active": True},
        new_value={"is_active": False, "reason": reason},
        ip_address=request.client.host if request and request.client else None,
        user_agent=request.headers.get("User-Agent") if request else None
    )
    return {"message": "Пользователь удален"}

@router.get("/users/{user_id}/events")
async def get_user_events(
    user_id: int,
    admin_user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """История входов/подключений/ошибок пользователя"""
    from models.telemetry import TelemetryEvent
    
    # События телеметрии
    events = db.query(TelemetryEvent).filter(
        TelemetryEvent.user_id == user_id
    ).order_by(TelemetryEvent.timestamp.desc()).limit(100).all()
    
    # История входов (admin_login_logs для админов, для обычных пользователей - через connection_logs)
    login_logs = []
    if admin_user.role in [UserRole.OWNER, UserRole.ADMIN, UserRole.SUPPORT, UserRole.READ_ONLY]:
        from models.admin_login_log import AdminLoginLog
        login_logs = db.query(AdminLoginLog).filter(
            AdminLoginLog.user_id == user_id
        ).order_by(AdminLoginLog.created_at.desc()).limit(50).all()
    
    # Connection logs
    connection_logs = db.query(ConnectionLog).filter(
        ConnectionLog.user_id == user_id
    ).order_by(ConnectionLog.connected_at.desc()).limit(100).all()
    
    return {
        "telemetry_events": [
            {
                "id": e.id,
                "event_type": e.event_type,
                "error_code": e.error_code,
                "error_message": e.error_message,
                "protocol_code": e.protocol_code,
                "server_id": e.server_id,
                "timestamp": e.timestamp.isoformat() if e.timestamp else None
            }
            for e in events
        ],
        "login_logs": [
            {
                "id": log.id,
                "ip_address": log.ip_address,
                "success": log.success,
                "failure_reason": log.failure_reason,
                "created_at": log.created_at.isoformat() if log.created_at else None
            }
            for log in login_logs
        ],
        "connection_logs": [
            {
                "id": log.id,
                "server_id": log.server_id,
                "connection_type": log.connection_type,
                "ip_address": log.ip_address,
                "connected_at": log.connected_at.isoformat() if log.connected_at else None,
                "disconnected_at": log.disconnected_at.isoformat() if log.disconnected_at else None,
                "duration_seconds": log.duration_seconds
            }
            for log in connection_logs
        ]
    }

@router.get("/users/{user_id}/devices")
async def get_user_devices(
    user_id: int,
    admin_user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Получение устройств пользователя"""
    devices = db.query(Device).filter(Device.user_id == user_id).all()
    
    return [
        {
            "id": device.id,
            "device_id": device.device_id,
            "device_name": device.device_name,
            "platform": device.platform,
            "model": device.model,
            "os_version": device.os_version,
            "app_version": device.app_version,
            "device_type": device.device_type,
            "is_active": device.is_active,
            "last_ip": device.last_ip,
            "last_country": device.last_country,
            "last_connected": device.last_connected.isoformat() if device.last_connected else None,
            "created_at": device.created_at.isoformat() if device.created_at else None
        }
        for device in devices
    ]

@router.get("/devices", response_model=DevicesResponse)
async def get_devices(
    page: int = 1,
    limit: int = 20,
    user_id: Optional[int] = None,
    platform: Optional[str] = None,
    is_active: Optional[bool] = None,
    search: Optional[str] = None,
    admin_user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Глобальный список устройств с фильтрами"""
    query = db.query(Device, User).join(User, Device.user_id == User.id)

    if user_id is not None:
        query = query.filter(Device.user_id == user_id)

    if platform:
        query = query.filter(Device.platform == platform)

    if is_active is not None:
        query = query.filter(Device.is_active == is_active)

    if search:
        pattern = f"%{search}%"
        query = query.filter(
            or_(
                Device.device_id.ilike(pattern),
                Device.device_name.ilike(pattern),
                User.email.ilike(pattern)
            )
        )

    total_count = query.count()
    skip = (page - 1) * limit
    devices = query.order_by(Device.created_at.desc()).offset(skip).limit(limit).all()

    items = [
        DeviceInfo(
            id=device.id,
            user_id=device.user_id,
            user_email=user.email,
            device_id=device.device_id,
            device_name=device.device_name,
            platform=device.platform,
            model=device.model,
            app_version=device.app_version,
            is_active=device.is_active,
            last_connected=device.last_connected,
            last_ip=device.last_ip,
            created_at=device.created_at
        )
        for device, user in devices
    ]

    return DevicesResponse(
        devices=items,
        total=total_count,
        page=page,
        limit=limit
    )

@router.get("/trials", response_model=TrialsResponse)
async def get_trials(
    page: int = 1,
    limit: int = 20,
    status: Optional[str] = None,
    user_id: Optional[int] = None,
    search: Optional[str] = None,
    admin_user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Список пользователей для управления триалами."""
    page = max(1, page)
    limit = min(max(1, limit), 500)
    query = db.query(User)

    if user_id is not None:
        query = query.filter(User.id == user_id)

    if search:
        pattern = f"%{search}%"
        query = query.filter(User.email.ilike(pattern))

    users = query.order_by(
        User.trial_started_at.desc().nullslast(),
        User.created_at.desc().nullslast(),
        User.id.desc(),
    ).all()
    now = datetime.utcnow()

    trials: List[TrialInfo] = []
    for user in users:
        remaining = 0
        if user.trial_active:
            if user.trial_started_at:
                elapsed = int((now - user.trial_started_at).total_seconds())
                remaining = max(0, (user.trial_seconds_left or 0) - elapsed)
            else:
                remaining = user.trial_seconds_left or 0
        status_value = "active" if user.trial_active and remaining > 0 else "expired"
        trial_end = None
        if user.trial_started_at and user.trial_seconds_left:
            trial_end = user.trial_started_at + timedelta(seconds=user.trial_seconds_left)
        if not user.trial_started_at and not user.trial_active and not (user.trial_seconds_left or 0):
            status_value = "not_started"

        if status == "active" and status_value != "active":
            continue
        if status == "expired" and status_value != "expired":
            continue
        if status == "not_started" and status_value != "not_started":
            continue

        trials.append(TrialInfo(
            user_id=user.id,
            email=user.email,
            status=status_value,
            trial_active=user.trial_active,
            trial_started_at=user.trial_started_at,
            trial_seconds_left=remaining,
            trial_ends_at=trial_end
        ))

    total_count = len(trials)
    start = (page - 1) * limit
    end = start + limit

    return TrialsResponse(
        trials=trials[start:end],
        total=total_count,
        page=page,
        limit=limit
    )

# Серверы
@router.get("/servers", response_model=ServersListResponse)
async def get_servers(
    user: User = Depends(require_admin),
    db: Session = Depends(get_db),
    page: int = 1,
    limit: int = 100
):
    """Получение списка серверов с пагинацией"""
    limit = min(max(1, limit), 500)
    total = db.query(Server).count()
    skip = (page - 1) * limit
    servers = db.query(Server).offset(skip).limit(limit).all()
    result = []
    for server in servers:
        health = _check_server_health(server)
        supported_protocols = _server_protocols(server)
        result.append(_build_server_info(server, health, supported_protocols))

    return ServersListResponse(servers=result, total=total, page=page, limit=limit)

@router.post("/servers", response_model=ServerInfo)
async def create_server(
    server_data: dict,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Создание нового сервера"""
    try:
        # Проверяем, не существует ли уже сервер с таким IP
        existing_server = db.query(Server).filter(Server.ip_address == server_data.get('ip_address')).first()
        if existing_server:
            raise HTTPException(status_code=400, detail="Сервер с таким IP адресом уже существует")
        
        # Устанавливаем значения по умолчанию
        if 'supported_protocols' not in server_data:
            server_data['supported_protocols'] = ["xray_vless"]
        if 'is_local' not in server_data:
            server_data['is_local'] = False
        if 'ssh_port' not in server_data:
            server_data['ssh_port'] = 22
        if 'ssh_user' not in server_data:
            server_data['ssh_user'] = "root"
        
        server = Server(**server_data)
        db.add(server)
        db.commit()
        db.refresh(server)
        
        health = _check_server_health(server)
        supported_protocols = server.get_supported_protocols() if hasattr(server, 'get_supported_protocols') else []
        if not supported_protocols:
            supported_protocols = ["xray_vless"]
        return _build_server_info(server, health, supported_protocols)
    except HTTPException:
        raise
    except Exception as e:
        db.rollback()
        raise HTTPException(status_code=400, detail=f"Ошибка создания сервера: {str(e)}")

@router.put("/servers/{server_id}", response_model=ServerInfo)
async def update_server(
    server_id: int,
    server_data: dict,
    admin_user: User = Depends(require_admin_or_owner),
    db: Session = Depends(get_db)
):
    """Обновление сервера"""
    server = db.query(Server).filter(Server.id == server_id).first()
    if not server:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Сервер не найден"
        )
    
    old_value = {k: getattr(server, k) for k in server_data.keys() if hasattr(server, k)}
    
    for key, value in server_data.items():
        if hasattr(server, key):
            setattr(server, key, value)
    
    server.updated_at = datetime.utcnow()
    db.commit()
    
    health = _check_server_health(server)
    supported_protocols = server.get_supported_protocols() if hasattr(server, 'get_supported_protocols') else []
    if not supported_protocols:
        supported_protocols = ["xray_vless"]
    return _build_server_info(server, health, supported_protocols)

@router.get("/servers/{server_id}", response_model=ServerInfo)
async def get_server_detail(
    server_id: int,
    admin_user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Детальная информация о сервере"""
    server = db.query(Server).filter(Server.id == server_id).first()
    if not server:
        raise HTTPException(status_code=404, detail="Сервер не найден")
    health = _check_server_health(server)
    supported_protocols = server.get_supported_protocols() if hasattr(server, 'get_supported_protocols') else []
    if not supported_protocols:
        supported_protocols = ["xray_vless"]
    return _build_server_info(server, health, supported_protocols)

class ServerStatusUpdate(BaseModel):
    status: str  # online, offline, draining, maintenance

@router.post("/servers/{server_id}/status", response_model=ServerInfo)
async def change_server_status(
    server_id: int,
    status_data: ServerStatusUpdate,
    admin_user: User = Depends(require_admin_or_owner),
    db: Session = Depends(get_db)
):
    """Изменение статуса сервера"""
    status = status_data.status
    if status not in ["online", "offline", "draining", "maintenance"]:
        raise HTTPException(status_code=400, detail="Недопустимый статус")
    
    server = db.query(Server).filter(Server.id == server_id).first()
    if not server:
        raise HTTPException(status_code=404, detail="Сервер не найден")
    
    old_status = server.status
    server.status = status
    server.updated_at = datetime.utcnow()
    db.commit()
    
    health = _check_server_health(server)
    supported_protocols = server.get_supported_protocols() if hasattr(server, 'get_supported_protocols') else []
    if not supported_protocols:
        supported_protocols = ["xray_vless"]
    return _build_server_info(server, health, supported_protocols)

@router.post("/servers/{server_id}/toggle", response_model=ServerInfo)
async def toggle_server_active(
    server_id: int,
    admin_user: User = Depends(require_admin_or_owner),
    db: Session = Depends(get_db)
):
    """Включить/выключить сервер (is_active)"""
    server = db.query(Server).filter(Server.id == server_id).first()
    if not server:
        raise HTTPException(status_code=404, detail="Сервер не найден")
    server.is_active = not server.is_active
    server.updated_at = datetime.utcnow()
    db.commit()
    health = _check_server_health(server)
    supported_protocols = server.get_supported_protocols() if hasattr(server, 'get_supported_protocols') else []
    if not supported_protocols:
        supported_protocols = ["xray_vless"]
    return _build_server_info(server, health, supported_protocols)

class EnqueueEdgeAssignmentRequest(BaseModel):
    """Постановка задания для edge-агента (poll через /api/internal/node/v1/assignment)."""
    assignment_type: str = Field(default="apply_xray_config", max_length=64)
    config_b64: str = Field(..., min_length=1, description="Base64 JSON конфига Xray")
    expected_hash: str = Field(..., min_length=1, max_length=256, description="Ожидаемый sha256:... после применения")
    deadline_at: Optional[datetime] = None


@router.post("/servers/{server_id}/edge-assignments")
async def enqueue_edge_node_assignment(
    server_id: int,
    body: EnqueueEdgeAssignmentRequest,
    admin_user: User = Depends(require_admin_or_owner),
    db: Session = Depends(get_db),
):
    """Создать задание в очереди для ноды (фаза 2 edge-агента)."""
    server = db.query(Server).filter(Server.id == server_id).first()
    if not server:
        raise HTTPException(status_code=404, detail="Сервер не найден")
    if not server.edge_agent_token_hash:
        raise HTTPException(
            status_code=400,
            detail="У сервера не настроен edge_agent_token_hash; агент не сможет авторизоваться",
        )
    aid = str(uuid.uuid4())
    payload = {
        "config_b64": body.config_b64,
        "expected_hash": body.expected_hash,
        "deadline_at": body.deadline_at.isoformat() + "Z" if body.deadline_at else None,
    }
    row = EdgeNodeAssignment(
        id=aid,
        server_id=server_id,
        assignment_type=body.assignment_type,
        payload_json=json.dumps(payload),
        status="pending",
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    return {"id": row.id, "server_id": server_id, "status": row.status, "assignment_type": row.assignment_type}


@router.delete("/servers/{server_id}")
async def delete_server(
    server_id: int,
    admin_user: User = Depends(require_owner),
    db: Session = Depends(get_db)
):
    """Удаление сервера с проверкой активных сессий"""
    server = db.query(Server).filter(Server.id == server_id).first()
    if not server:
        raise HTTPException(status_code=404, detail="Сервер не найден")
    
    # Проверяем активные сессии
    active_sessions = db.query(ConnectionLog).filter(
        ConnectionLog.server_id == server_id,
        ConnectionLog.disconnected_at == None
    ).count()
    
    if active_sessions > 0:
        raise HTTPException(
            status_code=400,
            detail=f"Невозможно удалить сервер: {active_sessions} активных сессий"
        )
    
    db.delete(server)
    db.commit()
    
    return {"message": "Сервер удален"}

@router.get("/servers/{server_id}/active-sessions")
async def get_server_active_sessions(
    server_id: int,
    admin_user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Активные сессии на сервере"""
    sessions = db.query(ConnectionLog).filter(
        ConnectionLog.server_id == server_id,
        ConnectionLog.disconnected_at == None
    ).all()
    
    return [
        {
            "id": s.id,
            "user_id": s.user_id,
            "device_id": s.device_id,
            "connected_at": s.connected_at.isoformat() if s.connected_at else None,
            "ip_address": s.ip_address
        }
        for s in sessions
    ]

# Тарифы
@router.get("/plans", response_model=List[PlanInfo])
async def get_plans(
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Получение списка тарифов"""
    plans = db.query(Plan).all()
    
    return [
        PlanInfo(
            id=plan.id,
            name=plan.name,
            description=plan.description,
            price=plan.price,
            duration_days=plan.duration_days,
            max_speed_mbps=plan.max_speed_mbps,
            max_devices=plan.max_devices,
            is_active=plan.is_active
        )
        for plan in plans
    ]

# Подписки
@router.get("/subscriptions", response_model=SubscriptionsResponse)
async def get_subscriptions(
    page: int = 1,
    limit: int = 20,
    status: Optional[str] = None,
    user_id: Optional[int] = None,
    plan_id: Optional[int] = None,
    start_date_from: Optional[str] = None,
    start_date_to: Optional[str] = None,
    end_date_from: Optional[str] = None,
    end_date_to: Optional[str] = None,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Список подписок"""
    query = db.query(Subscription).options(joinedload(Subscription.user), joinedload(Subscription.plan))
    
    if status:
        query = query.filter(Subscription.status == status)
    if user_id:
        query = query.filter(Subscription.user_id == user_id)
    if plan_id:
        query = query.filter(Subscription.plan_id == plan_id)
    start_from = _parse_iso_datetime(start_date_from)
    start_to = _parse_iso_datetime(start_date_to)
    end_from = _parse_iso_datetime(end_date_from)
    end_to = _parse_iso_datetime(end_date_to)
    if start_from:
        query = query.filter(Subscription.start_date >= start_from)
    if start_to:
        query = query.filter(Subscription.start_date <= start_to)
    if end_from:
        query = query.filter(Subscription.end_date >= end_from)
    if end_to:
        query = query.filter(Subscription.end_date <= end_to)
    
    total = query.count()
    skip = (page - 1) * limit
    subs = query.order_by(Subscription.created_at.desc()).offset(skip).limit(limit).all()
    
    result = [
        SubscriptionInfo(
            id=s.id,
            user_id=s.user_id,
            user_email=s.user.email if s.user else "",
            plan_id=s.plan_id,
            plan_name=s.plan.name if s.plan else None,
            status=s.status,
            start_date=s.start_date,
            end_date=s.end_date,
            auto_renew=bool(s.auto_renew),
            source=s.source,
            external_id=s.external_id
        )
        for s in subs
    ]
    
    return SubscriptionsResponse(subscriptions=result, total=total, page=page, limit=limit)

@router.get("/subscriptions/{subscription_id}", response_model=SubscriptionInfo)
async def get_subscription_detail(
    subscription_id: int,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Детали подписки"""
    subscription = db.query(Subscription).options(joinedload(Subscription.user), joinedload(Subscription.plan)).filter(
        Subscription.id == subscription_id
    ).first()
    if not subscription:
        raise HTTPException(status_code=404, detail="Подписка не найдена")
    
    return SubscriptionInfo(
        id=subscription.id,
        user_id=subscription.user_id,
        user_email=subscription.user.email if subscription.user else "",
        plan_id=subscription.plan_id,
        plan_name=subscription.plan.name if subscription.plan else None,
        status=subscription.status,
        start_date=subscription.start_date,
        end_date=subscription.end_date,
        auto_renew=bool(subscription.auto_renew),
        source=subscription.source,
        external_id=subscription.external_id
    )

@router.post("/plans")
async def create_plan(
    plan_data: dict,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Создание нового тарифа"""
    plan = Plan(**plan_data)
    db.add(plan)
    db.commit()
    db.refresh(plan)
    
    return {"message": "Тариф создан", "plan_id": plan.id}

@router.put("/plans/{plan_id}")
async def update_plan(
    plan_id: int,
    plan_data: dict,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Обновление тарифа"""
    plan = db.query(Plan).filter(Plan.id == plan_id).first()
    if not plan:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Тариф не найден"
        )
    
    for key, value in plan_data.items():
        setattr(plan, key, value)
    
    db.commit()
    
    return {"message": "Тариф обновлен"}

# Платежи
@router.get("/payments", response_model=PaymentsResponse)
async def get_payments(
    page: int = 1,
    limit: int = 20,
    status: Optional[str] = None,
    search: Optional[str] = None,
    created_from: Optional[str] = None,
    created_to: Optional[str] = None,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Получение списка платежей"""
    query = db.query(Payment).options(joinedload(Payment.user), joinedload(Payment.plan))
    
    if status:
        query = query.filter(Payment.status == status)
    
    if search:
        query = query.join(User, Payment.user_id == User.id).filter(User.email.ilike(f"%{search}%"))
    created_from_dt = _parse_iso_datetime(created_from)
    created_to_dt = _parse_iso_datetime(created_to)
    if created_from_dt:
        query = query.filter(Payment.created_at >= created_from_dt)
    if created_to_dt:
        query = query.filter(Payment.created_at <= created_to_dt)
    
    total = query.count()
    skip = (page - 1) * limit
    payments = query.order_by(Payment.created_at.desc()).offset(skip).limit(limit).all()
    
    result = [
        PaymentInfo(
            id=payment.id,
            user_id=payment.user_id,
            user_email=payment.user.email if payment.user else "",
            plan_id=payment.plan_id,
            plan_name=payment.plan.name if payment.plan else None,
            amount=payment.amount,
            currency=payment.currency,
            payment_method=payment.payment_method,
            status=payment.status,
            created_at=payment.created_at,
            updated_at=payment.updated_at,
            subscription_id=getattr(payment, "subscription_id", None)
        )
        for payment in payments
    ]
    
    return PaymentsResponse(payments=result, total=total, page=page, limit=limit)

@router.get("/payments/{payment_id}", response_model=PaymentInfo)
async def get_payment_detail(
    payment_id: int,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Детали платежа"""
    payment = db.query(Payment).options(joinedload(Payment.user), joinedload(Payment.plan)).filter(Payment.id == payment_id).first()
    if not payment:
        raise HTTPException(status_code=404, detail="Платеж не найден")
    
    return PaymentInfo(
        id=payment.id,
        user_id=payment.user_id,
        user_email=payment.user.email if payment.user else "",
        plan_id=payment.plan_id,
        plan_name=payment.plan.name if payment.plan else None,
        amount=payment.amount,
        currency=payment.currency,
        payment_method=payment.payment_method,
        status=payment.status,
        created_at=payment.created_at,
        updated_at=payment.updated_at,
        subscription_id=getattr(payment, "subscription_id", None)
    )

@router.get("/payments/user/{user_id}", response_model=List[PaymentInfo])
async def get_user_payments(
    user_id: int,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """История платежей пользователя"""
    payments = db.query(Payment).options(joinedload(Payment.user), joinedload(Payment.plan)).filter(
        Payment.user_id == user_id
    ).order_by(Payment.created_at.desc()).all()
    
    return [
        PaymentInfo(
            id=p.id,
            user_id=p.user_id,
            user_email=p.user.email if p.user else "",
            plan_id=p.plan_id,
            plan_name=p.plan.name if p.plan else None,
            amount=p.amount,
            currency=p.currency,
            payment_method=p.payment_method,
            status=p.status,
            created_at=p.created_at,
            updated_at=p.updated_at,
            subscription_id=getattr(p, "subscription_id", None)
        )
        for p in payments
    ]

@router.get("/payments/stats")
async def get_payment_stats(
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Статистика по платежам"""
    total_revenue = db.query(func.sum(Payment.amount)).filter(Payment.status == "completed").scalar() or 0.0
    
    # Статистика за последний месяц
    month_ago = datetime.utcnow() - timedelta(days=30)
    monthly_revenue = db.query(func.sum(Payment.amount)).filter(
        Payment.status == "completed",
        Payment.created_at >= month_ago
    ).scalar() or 0.0
    
    total_payments = db.query(Payment).count()
    successful_payments = db.query(Payment).filter(Payment.status == "completed").count()
    failed_payments = db.query(Payment).filter(Payment.status.in_(["failed", "cancelled"])).count()
    pending_payments = db.query(Payment).filter(Payment.status == "pending").count()
    
    return {
        "total_revenue": total_revenue,
        "monthly_revenue": monthly_revenue,
        "total_payments": total_payments,
        "successful_payments": successful_payments,
        "failed_payments": failed_payments,
        "pending_payments": pending_payments
    }

# Статистика
@router.get("/dashboard", response_model=DashboardStats)
async def get_dashboard_stats(
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Получение статистики для дашборда"""
    total_users = db.query(User).count()
    
    active_subscriptions = db.query(Subscription).filter(
        Subscription.status == "active",
        Subscription.end_date > datetime.utcnow()
    ).count()
    
    total_revenue = db.query(func.sum(Payment.amount)).filter(
        Payment.status == "completed"
    ).scalar() or 0.0
    
    active_connections = db.query(ConnectionLog).filter(
        ConnectionLog.connection_type == "connect",
        ConnectionLog.disconnected_at == None
    ).count()
    
    server_count = db.query(Server).filter(Server.is_active == True).count()
    
    return DashboardStats(
        total_users=total_users,
        active_subscriptions=active_subscriptions,
        total_revenue=total_revenue,
        active_connections=active_connections,
        server_count=server_count
    )

@router.get("/stats/auth-providers")
async def get_auth_provider_stats(
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Статистика регистраций по провайдерам"""
    rows = db.query(User.auth_provider, func.count(User.id)).group_by(User.auth_provider).all()
    stats = {row[0] or "unknown": row[1] for row in rows}
    return {
        "providers": stats,
        "total_users": sum(stats.values())
    }

# Логи подключений
@router.get("/logs/connections", response_model=ConnectionLogsResponse)
async def get_connection_logs(
    page: int = 1,
    limit: int = 100,
    user_id: Optional[int] = None,
    server_id: Optional[int] = None,
    connection_type: Optional[str] = None,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Получение логов подключений"""
    query = db.query(ConnectionLog)
    
    if user_id:
        query = query.filter(ConnectionLog.user_id == user_id)
    if server_id:
        query = query.filter(ConnectionLog.server_id == server_id)
    if connection_type:
        query = query.filter(ConnectionLog.connection_type == connection_type)
    
    total = query.count()
    skip = (page - 1) * limit
    logs = query.order_by(ConnectionLog.connected_at.desc()).offset(skip).limit(limit).all()
    
    result = [
        {
            "id": log.id,
            "user_id": log.user_id,
            "device_id": log.device_id,
            "server_id": log.server_id,
            "connection_type": log.connection_type,
            "ip_address": log.ip_address,
            "connected_at": log.connected_at.isoformat() if log.connected_at else None,
            "disconnected_at": log.disconnected_at.isoformat() if log.disconnected_at else None,
            "duration_seconds": log.duration_seconds,
            "vpn_session_id": getattr(log, "vpn_session_id", None)
        }
        for log in logs
    ]
    
    return ConnectionLogsResponse(logs=result, total=total, page=page, limit=limit)

@router.get("/logs/clients", response_model=ClientLogsResponse)
async def get_client_logs(
    page: int = 1,
    limit: int = 100,
    user_id: Optional[int] = None,
    device_id: Optional[int] = None,
    server_id: Optional[int] = None,
    event_type: Optional[str] = None,
    error_code: Optional[str] = None,
    protocol: Optional[str] = None,
    platform: Optional[str] = None,
    admin_user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Получение клиентских логов"""
    query = db.query(ClientLog)
    
    if user_id:
        query = query.filter(ClientLog.user_id == user_id)
    if device_id:
        query = query.filter(ClientLog.device_id == device_id)
    if server_id:
        query = query.filter(ClientLog.server_id == server_id)
    if event_type:
        query = query.filter(ClientLog.event_type == event_type)
    if error_code:
        query = query.filter(ClientLog.error_code == error_code)
    if protocol:
        query = query.filter(ClientLog.protocol == protocol)
    if platform:
        query = query.filter(ClientLog.platform == platform)
    
    total = query.count()
    skip = (page - 1) * limit
    logs = query.order_by(ClientLog.created_at.desc()).offset(skip).limit(limit).all()
    
    result = [
        {
            "id": log.id,
            "user_id": log.user_id,
            "device_id": log.device_id,
            "server_id": log.server_id,
            "event_type": log.event_type,
            "protocol": log.protocol,
            "client_id": log.client_id,
            "message": log.message,
            "error_code": log.error_code,
            "error_details": log.error_details,
            "app_version": log.app_version,
            "platform": log.platform,
            "os_version": log.os_version,
            "connection_duration_ms": log.connection_duration_ms,
            "bytes_sent": log.bytes_sent,
            "bytes_received": log.bytes_received,
            "vpn_session_id": getattr(log, "vpn_session_id", None),
            "created_at": log.created_at.isoformat() if log.created_at else None
        }
        for log in logs
    ]
    
    return ClientLogsResponse(logs=result, total=total, page=page, limit=limit)


@router.get("/support/diagnostics", response_model=SupportDiagnosticsResponse)
async def get_support_diagnostics(
    page: int = 1,
    limit: int = 100,
    user_id: Optional[int] = None,
    device_id: Optional[int] = None,
    email: Optional[str] = None,
    report_id: Optional[str] = None,
    context_minutes: int = 15,
    context_limit: int = 50,
    admin_user: User = Depends(require_support_or_above),
    db: Session = Depends(get_db)
):
    """Ручные диагностические отчеты, отправленные пользователями из приложения."""
    context_minutes = max(1, min(context_minutes, 120))
    context_limit = max(1, min(context_limit, 200))
    query = (
        db.query(ClientLog, User.email.label("user_email"))
        .join(User, User.id == ClientLog.user_id)
        .filter(ClientLog.event_type == "support_diagnostic_report")
    )

    if user_id:
        query = query.filter(ClientLog.user_id == user_id)
    if device_id:
        query = query.filter(ClientLog.device_id == device_id)
    if email:
        query = query.filter(User.email.ilike(f"%{email.strip()}%"))
    if report_id:
        query = query.filter(
            ClientLog.error_details["report_id"].astext == report_id.strip()
        )

    total = query.count()
    skip = (page - 1) * limit
    rows = (
        query.order_by(ClientLog.created_at.desc())
        .offset(skip)
        .limit(limit)
        .all()
    )

    reports = []
    for log, user_email in rows:
        details = log.error_details or {}
        window_from = (
            log.created_at - timedelta(minutes=context_minutes)
            if log.created_at
            else None
        )
        context_query = db.query(ClientLog).filter(
            ClientLog.user_id == log.user_id,
            ClientLog.id != log.id,
        )
        if log.device_id:
            context_query = context_query.filter(ClientLog.device_id == log.device_id)
        if window_from and log.created_at:
            context_query = context_query.filter(
                ClientLog.created_at >= window_from,
                ClientLog.created_at <= log.created_at,
            )
        context_logs = (
            context_query.order_by(ClientLog.created_at.desc())
            .limit(context_limit)
            .all()
        )
        context_events = [
            {
                "id": ctx.id,
                "created_at": ctx.created_at.isoformat() if ctx.created_at else None,
                "event_type": ctx.event_type,
                "protocol": ctx.protocol,
                "server_id": ctx.server_id,
                "message": ctx.message,
                "error_code": ctx.error_code,
                "error_details": ctx.error_details,
                "app_version": ctx.app_version,
                "platform": ctx.platform,
                "os_version": ctx.os_version,
                "vpn_session_id": getattr(ctx, "vpn_session_id", None),
            }
            for ctx in context_logs
        ]
        reports.append({
            "id": log.id,
            "user_id": log.user_id,
            "user_email": user_email,
            "device_id": log.device_id,
            "server_id": log.server_id,
            "protocol": log.protocol,
            "message": log.message,
            "error_code": log.error_code,
            "error_details": details,
            "report_id": details.get("report_id"),
            "app_version": details.get("app_version") or log.app_version,
            "build_number": details.get("build_number"),
            "access_status": details.get("access_status"),
            "vpn_state": details.get("vpn_state"),
            "server": details.get("server"),
            "last_error": details.get("last_error"),
            "context_minutes": context_minutes,
            "context_events": context_events,
            "created_at": log.created_at.isoformat() if log.created_at else None,
        })

    return SupportDiagnosticsResponse(
        reports=reports,
        total=total,
        page=page,
        limit=limit,
    )


@router.get("/users/{user_id}/diagnostics")
async def get_user_diagnostics(
    user_id: int,
    from_time: Optional[str] = None,
    to_time: Optional[str] = None,
    server_id: Optional[int] = None,
    limit: int = 200,
    include_server_logs: bool = False,
    admin_user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """
    Объединённая диагностика по пользователю: client_logs + connection_logs + опционально логи сервера.
    События возвращаются в одном списке, отсортированы по времени (новые первые).
    """
    limit = min(limit, 500)
    dt_from = _parse_iso_datetime(from_time)
    dt_to = _parse_iso_datetime(to_time)

    # Проверяем, что пользователь существует
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="Пользователь не найден")

    events = []

    # 1. Client logs
    cl_query = db.query(ClientLog).filter(ClientLog.user_id == user_id)
    if server_id is not None:
        cl_query = cl_query.filter(ClientLog.server_id == server_id)
    if dt_from:
        cl_query = cl_query.filter(ClientLog.created_at >= dt_from)
    if dt_to:
        cl_query = cl_query.filter(ClientLog.created_at <= dt_to)
    cl_logs = cl_query.order_by(ClientLog.created_at.desc()).limit(limit).all()
    for log in cl_logs:
        ts = log.created_at.isoformat() if log.created_at else None
        events.append({
            "timestamp": ts,
            "source": "client_log",
            "id": log.id,
            "event_type": log.event_type,
            "protocol": log.protocol,
            "client_id": log.client_id,
            "message": log.message,
            "error_code": log.error_code,
            "error_details": log.error_details,
            "server_id": log.server_id,
            "device_id": log.device_id,
            "app_version": log.app_version,
            "platform": log.platform,
            "connection_duration_ms": log.connection_duration_ms,
            "vpn_session_id": getattr(log, "vpn_session_id", None),
        })

    # 2. Connection logs (connect/disconnect)
    conn_query = db.query(ConnectionLog).filter(ConnectionLog.user_id == user_id)
    if server_id is not None:
        conn_query = conn_query.filter(ConnectionLog.server_id == server_id)
    if dt_from:
        conn_query = conn_query.filter(ConnectionLog.connected_at >= dt_from)
    if dt_to:
        conn_query = conn_query.filter(ConnectionLog.connected_at <= dt_to)
    conn_logs = conn_query.order_by(ConnectionLog.connected_at.desc()).limit(limit).all()
    for log in conn_logs:
        ts = (log.disconnected_at or log.connected_at)
        ts = ts.isoformat() if ts else None
        events.append({
            "timestamp": ts,
            "source": "connection_log",
            "id": log.id,
            "connection_type": log.connection_type,
            "server_id": log.server_id,
            "device_id": log.device_id,
            "ip_address": log.ip_address,
            "connected_at": log.connected_at.isoformat() if log.connected_at else None,
            "disconnected_at": log.disconnected_at.isoformat() if log.disconnected_at else None,
            "duration_seconds": log.duration_seconds,
            "vpn_session_id": getattr(log, "vpn_session_id", None),
        })

    # 3. Опционально: последние логи сервера (если передан server_id и include_server_logs)
    server_log_entries = []
    if include_server_logs and server_id:
        server_obj = db.query(Server).filter(Server.id == server_id).first()
        if server_obj:
            try:
                from services.remote_vpn_manager import RemoteVPNManager
                remote_manager = RemoteVPNManager()
                if remote_manager.ssh_manager:
                    xray_res = remote_manager.get_xray_logs(server_obj, log_type="error", lines=50)
                    if xray_res.get("success") and xray_res.get("logs"):
                        for line in xray_res.get("logs", [])[:50]:
                            server_log_entries.append({
                                "timestamp": None,
                                "source": "server_log",
                                "protocol": "xray",
                                "log_type": xray_res.get("log_type"),
                                "line": line,
                            })
                    wg_res = remote_manager.get_wireguard_logs(server_obj, lines=50)
                    if wg_res.get("success") and wg_res.get("logs"):
                        for line in wg_res.get("logs", [])[:50]:
                            server_log_entries.append({
                                "timestamp": None,
                                "source": "server_log",
                                "protocol": "wireguard",
                                "log_type": "wireguard",
                                "line": line,
                            })
            except Exception:
                pass

    for e in server_log_entries:
        events.append(e)

    # Сортировка по времени (новые первые); без timestamp в конец
    def sort_key(e):
        t = e.get("timestamp")
        if not t:
            return ""
        return t

    events.sort(key=sort_key, reverse=True)
    events = events[:limit]

    return {"user_id": user_id, "events": events, "count": len(events)}


# Текущий пользователь
@router.get("/me")
async def get_current_user(
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Получение информации о текущем пользователе"""
    return {
        "id": user.id,
        "email": user.email,
        "username": user.email.split('@')[0],  # Используем часть email как username
        "role": user.role.value if user.role else "admin",
        "isActive": user.is_active,
        "createdAt": user.created_at.isoformat()
    }

# Новые endpoints для мониторинга серверов
@router.get("/servers/stats")
async def get_servers_stats(
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Общая статистика серверов"""
    servers = db.query(Server).limit(1000).all()
    active_servers = [s for s in servers if s.is_active]
    
    total_users = sum(s.current_users for s in servers)
    total_max_users = sum(s.max_users for s in servers)
    total_load = sum(s.load_percentage for s in servers)
    average_load = total_load / len(servers) if servers else 0.0
    
    total_bandwidth_used = sum(s.bandwidth_used_mbps for s in servers)
    total_bandwidth_limit = sum(s.bandwidth_limit_mbps for s in servers if s.bandwidth_limit_mbps)
    
    return {
        "total_servers": len(servers),
        "active_servers": len(active_servers),
        "total_users": total_users,
        "total_max_users": total_max_users,
        "average_load": round(average_load, 2),
        "total_bandwidth_used_mbps": round(total_bandwidth_used, 2),
        "total_bandwidth_limit_mbps": round(total_bandwidth_limit, 2) if total_bandwidth_limit else None,
        "timestamp": datetime.utcnow().isoformat()
    }

@router.get("/servers/{server_id}/load")
async def get_server_load(
    server_id: int,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Детальная нагрузка сервера"""
    server = db.query(Server).filter(Server.id == server_id).first()
    if not server:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Сервер не найден"
        )
    
    calculator = ServerLoadCalculator(db)
    result = calculator.update_server_load(server)
    
    return result

@router.get("/servers/{server_id}/stats")
async def get_server_stats(
    server_id: int,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Статистика сервера (уникальные пользователи, ошибки, время коннекта)"""
    server = db.query(Server).filter(Server.id == server_id).first()
    if not server:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Сервер не найден"
        )
    
    # Уникальные пользователи за последние 24 часа
    from datetime import timedelta
    day_ago = datetime.utcnow() - timedelta(days=1)
    unique_users_24h = db.query(func.count(func.distinct(ConnectionLog.user_id))).filter(
        ConnectionLog.server_id == server_id,
        ConnectionLog.connected_at >= day_ago
    ).scalar() or 0
    
    # Уникальные пользователи за последние 7 дней
    week_ago = datetime.utcnow() - timedelta(days=7)
    unique_users_7d = db.query(func.count(func.distinct(ConnectionLog.user_id))).filter(
        ConnectionLog.server_id == server_id,
        ConnectionLog.connected_at >= week_ago
    ).scalar() or 0
    
    # Уникальные пользователи за последние 30 дней
    month_ago = datetime.utcnow() - timedelta(days=30)
    unique_users_30d = db.query(func.count(func.distinct(ConnectionLog.user_id))).filter(
        ConnectionLog.server_id == server_id,
        ConnectionLog.connected_at >= month_ago
    ).scalar() or 0
    
    # Ошибки за последние 24 часа
    from models.telemetry import TelemetryEvent
    errors_24h = db.query(TelemetryEvent).filter(
        TelemetryEvent.server_id == server_id,
        TelemetryEvent.error_code.isnot(None),
        TelemetryEvent.timestamp >= day_ago
    ).count()
    
    # Среднее время подключения за последние 24 часа
    avg_duration = db.query(func.avg(ConnectionLog.duration_seconds)).filter(
        ConnectionLog.server_id == server_id,
        ConnectionLog.connected_at >= day_ago,
        ConnectionLog.duration_seconds.isnot(None)
    ).scalar() or 0
    
    return {
        "server_id": server_id,
        "server_name": server.name,
        "unique_users_24h": unique_users_24h,
        "unique_users_7d": unique_users_7d,
        "unique_users_30d": unique_users_30d,
        "errors_24h": errors_24h,
        "average_connection_duration_seconds": round(float(avg_duration), 2) if avg_duration else 0,
        "current_users": server.current_users,
        "max_users": server.max_users,
        "load_percentage": server.load_percentage if hasattr(server, 'load_percentage') else 0,
        "timestamp": datetime.utcnow().isoformat()
    }

@router.get("/servers/{server_id}/protocols")
async def get_server_protocols(
    server_id: int,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Статистика по протоколам сервера"""
    server = db.query(Server).filter(Server.id == server_id).first()
    if not server:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Сервер не найден"
        )
    
    from models.protocol_stats import ProtocolStats
    from datetime import date, timedelta
    
    # Получаем статистику за последние 7 дней
    start_date = date.today() - timedelta(days=7)
    stats = db.query(ProtocolStats).filter(
        ProtocolStats.server_id == server_id,
        ProtocolStats.date >= start_date
    ).all()
    
    # Группируем по протоколам
    protocol_stats = {}
    for stat in stats:
        if stat.protocol not in protocol_stats:
            protocol_stats[stat.protocol] = {
                "total_connections": 0,
                "successful_connections": 0,
                "failed_connections": 0,
                "average_speed_mbps": 0.0,
                "average_ping_ms": 0.0,
                "uptime_percentage": 0.0
            }
        
        protocol_stats[stat.protocol]["total_connections"] += stat.total_connections
        protocol_stats[stat.protocol]["successful_connections"] += stat.successful_connections
        protocol_stats[stat.protocol]["failed_connections"] += stat.failed_connections
    
    # Вычисляем средние значения
    for protocol, data in protocol_stats.items():
        protocol_data = [s for s in stats if s.protocol == protocol]
        if protocol_data:
            data["average_speed_mbps"] = sum(s.average_speed_mbps for s in protocol_data) / len(protocol_data)
            data["average_ping_ms"] = sum(s.average_ping_ms for s in protocol_data) / len(protocol_data)
            data["uptime_percentage"] = sum(s.uptime_percentage for s in protocol_data) / len(protocol_data)
    
    return {
        "server_id": server_id,
        "server_name": server.name,
        "supported_protocols": server.get_supported_protocols(),
        "protocol_stats": protocol_stats,
        "timestamp": datetime.utcnow().isoformat()
    }

@router.get("/servers/{server_id}/users")
async def get_server_users(
    server_id: int,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Активные пользователи на сервере"""
    devices = db.query(Device).filter(
        Device.current_server_id == server_id,
        Device.is_active == True
    ).all()
    
    return [
        {
            "device_id": d.id,
            "user_id": d.user_id,
            "device_name": d.device_name,
            "device_type": d.device_type,
            "ip_address": d.ip_address,
            "last_connected": d.last_connected.isoformat() if d.last_connected else None
        }
        for d in devices
    ]

# Endpoints для провайдеров
@router.get("/providers")
async def get_providers(
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Список провайдеров"""
    monitor = ProviderMonitor(db)
    providers = monitor.get_all_providers()
    
    return {
        "providers": providers,
        "total": len(providers)
    }

@router.get("/providers/stats")
async def get_providers_stats(
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Статистика по провайдерам"""
    monitor = ProviderMonitor(db)
    stats = monitor.get_all_providers_stats()
    
    return {
        "providers": stats,
        "total": len(stats),
        "timestamp": datetime.utcnow().isoformat()
    }

@router.get("/providers/{provider_name}/stats")
async def get_provider_stats(
    provider_name: str,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Статистика конкретного провайдера"""
    monitor = ProviderMonitor(db)
    stats = monitor.get_provider_stats(provider_name)
    
    return stats

@router.get("/providers/{provider_name}/servers")
async def get_provider_servers(
    provider_name: str,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Серверы провайдера"""
    monitor = ProviderMonitor(db)
    servers = monitor.get_provider_servers(provider_name)
    
    return {
        "provider": provider_name,
        "servers": servers,
        "total": len(servers)
    }

@router.get("/providers/comparison")
async def compare_providers(
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Сравнение провайдеров"""
    monitor = ProviderMonitor(db)
    comparison = monitor.compare_providers()
    
    return comparison

# Endpoints для протоколов
@router.get("/protocols/stats")
async def get_protocols_stats(
    days: int = 7,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Статистика по протоколам"""
    analyzer = ProtocolAnalyzer(db)
    
    protocols = ['xray_reality', 'xray_vless', 'xray_vmess']
    stats = {}
    
    for protocol in protocols:
        perf = analyzer.get_protocol_performance(protocol, days)
        if 'error' not in perf:
            stats[protocol] = perf
    
    return {
        "protocols": stats,
        "period_days": days,
        "timestamp": datetime.utcnow().isoformat()
    }

@router.get("/protocols/{protocol_name}/performance")
async def get_protocol_performance(
    protocol_name: str,
    days: int = 7,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Производительность протокола"""
    analyzer = ProtocolAnalyzer(db)
    performance = analyzer.get_protocol_performance(protocol_name, days)
    
    return performance

@router.get("/protocols/recommendations")
async def get_protocol_recommendations(
    country: Optional[str] = None,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Рекомендации по протоколам"""
    analyzer = ProtocolAnalyzer(db)
    recommendations = analyzer.get_protocol_recommendations(country)
    
    return recommendations

# Endpoints для нагрузки
@router.get("/load/overview")
async def get_load_overview(
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Обзор нагрузки всех серверов"""
    calculator = ServerLoadCalculator(db)
    result = calculator.update_all_servers_load()
    
    return result

@router.get("/load/alerts")
async def get_load_alerts(
    threshold: float = 80.0,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Предупреждения о перегрузке"""
    calculator = ServerLoadCalculator(db)
    alerts = calculator.get_load_alerts(threshold)
    
    return {
        "alerts": alerts,
        "threshold": threshold,
        "count": len(alerts),
        "timestamp": datetime.utcnow().isoformat()
    }

# Эндпоинты для просмотра кодов авторизации
@router.get("/auth-codes")
async def get_auth_codes(
    email: Optional[str] = None,
    skip: int = 0,
    limit: int = 100,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Получение списка кодов авторизации"""
    query = db.query(AuthCode)
    
    if email:
        query = query.filter(func.lower(AuthCode.email) == email.lower())
    
    codes = query.order_by(AuthCode.created_at.desc()).offset(skip).limit(limit).all()
    
    result = []
    for code in codes:
        # Проверяем, истек ли код
        is_expired = code.expires_at < datetime.utcnow()
        
        result.append({
            "id": code.id,
            "email": code.email,
            "code_hash": code.code_hash,
            "expires_at": code.expires_at.isoformat(),
            "is_expired": is_expired,
            "attempts_count": code.attempts_count,
            "created_at": code.created_at.isoformat(),
            "ip_address": code.ip_address,
            "time_left_seconds": max(0, int((code.expires_at - datetime.utcnow()).total_seconds())) if not is_expired else 0
        })
    
    return {
        "codes": result,
        "total": len(result),
        "email_filter": email
    }

@router.get("/auth-codes/{code_id}")
async def get_auth_code_detail(
    code_id: int,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Детальная информация о коде"""
    code = db.query(AuthCode).filter(AuthCode.id == code_id).first()
    
    if not code:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Код не найден"
        )
    
    is_expired = code.expires_at < datetime.utcnow()
    
    return {
        "id": code.id,
        "email": code.email,
        "code_hash": code.code_hash,
        "expires_at": code.expires_at.isoformat(),
        "is_expired": is_expired,
        "attempts_count": code.attempts_count,
        "created_at": code.created_at.isoformat(),
        "ip_address": code.ip_address,
        "time_left_seconds": max(0, int((code.expires_at - datetime.utcnow()).total_seconds())) if not is_expired else 0
    }

@router.get("/users/{user_id}/verification-codes")
async def get_user_verification_codes(
    user_id: int,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Получение кодов авторизации для конкретного пользователя"""
    target_user = db.query(User).filter(User.id == user_id).first()
    
    if not target_user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Пользователь не найден"
        )
    
    # Коды из auth_codes
    auth_codes = db.query(AuthCode).filter(
        func.lower(AuthCode.email) == target_user.email.lower()
    ).order_by(AuthCode.created_at.desc()).all()
    
    codes_list = []
    for code in auth_codes:
        is_expired = code.expires_at < datetime.utcnow()
        codes_list.append({
            "id": code.id,
            "code_hash": code.code_hash,
            "expires_at": code.expires_at.isoformat(),
            "is_expired": is_expired,
            "attempts_count": code.attempts_count,
            "created_at": code.created_at.isoformat(),
            "source": "auth_codes"
        })
    
    # Старый код из user.verification_code (если есть)
    old_code = None
    if hasattr(target_user, 'verification_code') and target_user.verification_code:
        is_expired_old = target_user.verification_code_expires and target_user.verification_code_expires < datetime.utcnow()
        old_code = {
            "code": target_user.verification_code,  # Показываем plain код для отладки
            "expires_at": target_user.verification_code_expires.isoformat() if target_user.verification_code_expires else None,
            "is_expired": is_expired_old,
            "source": "user.verification_code"
        }
    
    return {
        "user_id": target_user.id,
        "user_email": target_user.email,
        "auth_codes": codes_list,
        "old_verification_code": old_code,
        "total_codes": len(codes_list) + (1 if old_code else 0)
    }

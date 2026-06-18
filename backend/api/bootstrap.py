"""
Bootstrap endpoint для устойчивого получения списка URL API (сценарий 6 обхода блокировок).

Публичный endpoint без авторизации: приложение может запросить список api_base_urls
с «прикрывающего» домена или после DoH, чтобы при блокировке основного домена
продолжать работать. См. docs/VPN_BYPASS_SCENARIOS.md, docs/VPN_BYPASS_TESTING_AND_INTEGRATION.md.
"""
from fastapi import APIRouter, Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel
from sqlalchemy.orm import Session
from typing import Any, Dict, List

from core.config import settings
from core.database import get_db
from core.constants import (
    XRAY_REALITY_DEFAULT_PORT,
    XRAY_VLESS_GRPC_TLS_DEFAULT_PORT,
    XRAY_VLESS_DEFAULT_PORT,
    XRAY_VLESS_WS_TLS_DEFAULT_PORT,
    XRAY_VMESS_DEFAULT_PORT,
)
from domain.models.protocol import Protocol
from domain.models.server import Server
from services.auth_service import AuthService
from services.trial_service import get_active_subscription_details, get_user_access_info
from api.vpn import _ensure_xray_defaults

router = APIRouter(prefix="/api/vpn", tags=["Bootstrap"])
security = HTTPBearer()

# Всегда предлагаем клиенту Cloudflare-first API host.
_GRANILINK_API_BASE = "https://api.granilink.com/api"


class BootstrapResponse(BaseModel):
    api_base_urls: List[str]
    ttl_seconds: int = 3600
    # Ожидаемые порты в клиентском конфиге (совпадают с core/constants.py); клиент валидирует кэш.
    xray_expected_ports: Dict[str, int]


class ControlPlaneSnapshotResponse(BaseModel):
    user: Dict[str, Any]
    servers: List[Dict[str, Any]]
    ttl_seconds: int = 60


@router.get("/bootstrap", response_model=BootstrapResponse)
async def get_bootstrap_config() -> BootstrapResponse:
    """
    Возвращает список базовых URL API для запросов приложения.
    Используется для censorship-resilient bootstrap: приложение может получить этот JSON
    с альтернативного хоста (CDN/зеркало) или после DoH и использовать urls по порядку.
    """
    base = (settings.api_url or "").rstrip("/")
    main_url = f"{base}/api" if base else ""
    urls: List[str] = [main_url] if main_url else []
    fallbacks_raw = getattr(settings, "api_base_url_fallbacks", "") or ""
    for u in fallbacks_raw.split(","):
        u = u.strip()
        if u and u not in urls:
            urls.append(u)
    # Cloudflare-fronted control-plane. Не добавляем :8444 для этого hostname:
    # Cloudflare не проксирует такой запасной порт, поэтому клиент не должен
    # получать его из bootstrap.
    if _GRANILINK_API_BASE not in urls:
        urls.append(_GRANILINK_API_BASE)
    ports: Dict[str, int] = {
        "xray_vless": XRAY_VLESS_DEFAULT_PORT,
        "xray_vmess": XRAY_VMESS_DEFAULT_PORT,
        "xray_reality": XRAY_REALITY_DEFAULT_PORT,
        "xray_vless_ws_tls": XRAY_VLESS_WS_TLS_DEFAULT_PORT,
        "xray_vless_grpc_tls": XRAY_VLESS_GRPC_TLS_DEFAULT_PORT,
    }
    return BootstrapResponse(
        api_base_urls=urls,
        ttl_seconds=3600,
        xray_expected_ports=ports,
    )


@router.get("/control-plane-snapshot", response_model=ControlPlaneSnapshotResponse)
async def get_control_plane_snapshot(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
) -> ControlPlaneSnapshotResponse:
    user = AuthService.get_current_user(credentials.credentials, db)
    trial_seconds_left, has_active_subscription = get_user_access_info(user.id, db)
    sub_details = get_active_subscription_details(user.id, db)
    user_payload: Dict[str, Any] = {
        "id": user.id,
        "email": user.email,
        "is_active": user.is_active,
        "is_verified": user.is_verified,
        "auth_provider": user.auth_provider,
        "preferred_language": user.preferred_language or "en",
        "created_at": user.created_at.isoformat() if user.created_at else None,
        "updated_at": user.updated_at.isoformat() if user.updated_at else None,
        "trialSecondsLeft": trial_seconds_left,
        "trial_seconds_left": trial_seconds_left,
        "hasActiveSubscription": has_active_subscription,
        "has_active_subscription": has_active_subscription,
        **sub_details,
    }

    servers = db.query(Server).filter(Server.is_active.is_(True)).all()
    _ensure_xray_defaults(db, servers)
    enabled_rows = db.query(Protocol.code).filter(Protocol.status == "enabled").all()
    enabled_protocol_codes = {row.code for row in enabled_rows} or {
        "xray_vless",
        "xray_vmess",
        "xray_vless_ws_tls",
        "xray_vless_grpc_tls",
    }
    enabled_protocol_codes.update({"xray_vless_ws_tls", "xray_vless_grpc_tls"})

    payload_servers: List[Dict[str, Any]] = []
    for server in servers:
        try:
            supported_protocols = (
                server.get_supported_protocols()
                if hasattr(server, "get_supported_protocols")
                else getattr(server, "supported_protocols", None)
            ) or []
        except Exception:
            supported_protocols = []
        if isinstance(supported_protocols, str):
            try:
                import json
                supported_protocols = json.loads(supported_protocols)
            except Exception:
                supported_protocols = []
        if not isinstance(supported_protocols, list):
            supported_protocols = []
        protocols = [p for p in supported_protocols if p in enabled_protocol_codes]
        if not protocols:
            protocols = [p for p in ["xray_vless"] if p in enabled_protocol_codes]

        payload_servers.append(
            {
                "id": server.id,
                "name": server.name,
                "country": server.country,
                "city": server.city,
                "ip_address": server.ip_address,
                "port": server.port,
                "current_users": server.current_users or 0,
                "max_users": server.max_users or 0,
                "is_active": bool(server.is_active),
                "health_status": (
                    server.health_status
                    if server.health_status in {"healthy", "warning", "error"}
                    else "unknown"
                ),
                "supported_protocols": protocols,
                "wireguard_port": server.wireguard_port,
                "wireguard_public_key": server.wireguard_public_key,
                "flag_url": getattr(server, "flag_url", None),
                "ping_ms": getattr(server, "ping_ms", None),
                "xray_port": getattr(server, "xray_port", None),
            }
        )

    return ControlPlaneSnapshotResponse(
        user=user_payload,
        servers=payload_servers,
        ttl_seconds=60,
    )

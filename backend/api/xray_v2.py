from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel
from typing import Optional, Dict, Any
import logging

from core.dependencies import get_vpn_operations_service
from application.services.vpn_operations_service import VPNOperationsService
from services.auth_service import AuthService
from core.config import settings

router = APIRouter(prefix="/api/v2/vpn/xray", tags=["Xray VPN V2"])
security = HTTPBearer()
logger = logging.getLogger(__name__)

MINIMAL_VPN_MODE = False
MINIMAL_VPN_SERVER_ID = 3  # UK-LON-01
MINIMAL_VPN_PROTOCOL = "xray_reality"



class V2XrayConnectRequest(BaseModel):
    server_id: int
    device_id: Optional[str] = None
    fingerprint: Optional[str] = None
    protocol: str = "xray_vless"
    traffic_profile: Optional[str] = None


class V2XrayConnectResponse(BaseModel):
    success: bool
    protocol: str
    client_id: str
    config: Optional[str] = None
    json_config: Optional[Dict[str, Any]] = None
    config_revision: Optional[str] = None
    server: Dict[str, Any]
    message: str


def _ensure_v2_protocol(protocol: str) -> str:
    value = str(protocol or "").strip().lower()
    if value == "vless":
        value = "xray_vless"
    elif value == "reality":
        value = "xray_reality"
    elif value == "vmess":
        value = "xray_vmess"

    allowed = {"xray_vless", "xray_reality", "xray_vmess"}
    if value not in allowed:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=(
                "V2 контур поддерживает только "
                "protocol=xray_vless, protocol=xray_reality или protocol=xray_vmess"
            ),
        )
    return value


def _resolve_v2_protocol(protocol: str, traffic_profile: Optional[str]) -> str:
    resolved = _ensure_v2_protocol(protocol)
    profile = str(traffic_profile or "").strip().lower()
    # Diagnostic 2026-05-12: preserve explicit VLESS.
    # The old working APK used legacy /vpn/xray/create-client and kept xray_vless
    # on plain VLESS@4443. The v2 throughput remap silently converted VLESS to
    # REALITY, which does not match HU's working server-side profile.
    if resolved == "xray_vless":
        if profile in {"throughput", "heavy", "speedtest"}:
            logger.warning(
                "xray-v2 connect: preserve explicit xray_vless despite traffic_profile=%s",
                profile,
            )
        return resolved
    return resolved


@router.post("/connect", response_model=V2XrayConnectResponse)
async def connect_xray_v2(
    request: V2XrayConnectRequest,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    vpn_service: VPNOperationsService = Depends(get_vpn_operations_service),
):
    """
    Чистый v2-контур подключения:
    - xray_vless и xray_reality
    - без session/prepare кэшей, lock'ов и long-poll apply-state
    """
    effective_server_id = request.server_id
    effective_protocol_request = request.protocol
    effective_traffic_profile = request.traffic_profile
    if MINIMAL_VPN_MODE:
        logger.warning(
            "xray-v2 minimal mode: forcing server_id=%s protocol=%s; requested server_id=%s protocol=%s traffic_profile=%s",
            MINIMAL_VPN_SERVER_ID,
            MINIMAL_VPN_PROTOCOL,
            request.server_id,
            request.protocol,
            request.traffic_profile or "(none)",
        )
        effective_server_id = MINIMAL_VPN_SERVER_ID
        effective_protocol_request = MINIMAL_VPN_PROTOCOL
        effective_traffic_profile = None

    requested_protocol = _ensure_v2_protocol(effective_protocol_request)
    if not MINIMAL_VPN_MODE and requested_protocol in {"xray_vless", "xray_vmess"}:
        logger.warning(
            "xray-v2 connect: diagnostic legacy fallback for explicit legacy Xray protocol "
            "server_id=%s device_id=%s traffic_profile=%s",
            effective_server_id,
            request.device_id or "(none)",
            effective_traffic_profile or "(none)",
        )
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Diagnostic: use legacy /vpn/xray/create-client for legacy Xray protocol",
        )

    protocol = _resolve_v2_protocol(effective_protocol_request, effective_traffic_profile)
    user = AuthService.get_current_user(credentials.credentials, vpn_service.db)
    server = vpn_service.validate_and_get_server(effective_server_id)

    logger.warning(
        "xray-v2 connect: user_id=%s server_id=%s device_id=%s protocol=%s traffic_profile=%s",
        user.id,
        server.id,
        request.device_id or "(none)",
        protocol,
        effective_traffic_profile or ("minimal" if MINIMAL_VPN_MODE else "(default)"),
    )

    try:
        result = vpn_service.get_existing_connection_config(
            user=user,
            server=server,
            protocol=protocol,
            device_id=request.device_id,
            device_fingerprint=request.fingerprint,
        )
    except HTTPException as e:
        # First real connect path: создаём/применяем на ноде только при фактическом запросе connect.
        if e.status_code != status.HTTP_409_CONFLICT:
            raise
        if not request.device_id or not request.device_id.strip():
            result = vpn_service.get_or_create_connection(user, server, protocol)
        else:
            device_id = request.device_id.strip()
            device_data = {
                "name": f"Device {device_id[:8]}",
                "device_id": device_id,
                "platform": "unknown",
            }
            if request.fingerprint and request.fingerprint.strip():
                device_data["fingerprint"] = request.fingerprint.strip()
            device = vpn_service.validate_and_get_device(
                user,
                device_id,
                auto_register=True,
                device_data=device_data,
            )
            result = vpn_service.connect_device(user, device, server, protocol)

    if not result.get("success"):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=result.get("error") or "Не удалось получить Xray v2 клиента",
        )

    client_id = str(result.get("client_id") or "").strip()
    if not client_id:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Xray v2 вернул пустой client_id",
        )

    return V2XrayConnectResponse(
        success=True,
        protocol=protocol,
        client_id=client_id,
        config=result.get("config"),
        json_config=result.get("json_config"),
        config_revision=result.get("config_revision"),
        server={
            "id": server.id,
            "name": server.name,
            "ip_address": getattr(server, "ip_address", None),
            "xray_port": getattr(server, "xray_port", None),
        },
        message="Xray v2 minimal client получен" if MINIMAL_VPN_MODE else "Xray v2 клиент получен",
    )

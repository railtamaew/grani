"""
VPN Manager Facade: single entry for connect/disconnect with retry and logging.
"""
import logging
import time
from fastapi import HTTPException
from application.services.vpn_operations_service import VPNOperationsService
logger = logging.getLogger(__name__)
MAX_RETRIES = 2
INITIAL_DELAY = 1.0
BACKOFF = 2.0

class VPNManagerFacade:
    def __init__(self, vpn_operations_service: VPNOperationsService):
        self._vpn = vpn_operations_service

    def connect_vpn(self, user, device_id: str, server_id: int, protocol=None, device_data=None, client_ip=None):
        protocol = protocol or "xray_vless"
        device_data = device_data or {}
        start = time.monotonic()
        last_error = None
        for attempt in range(MAX_RETRIES + 1):
            try:
                logger.info(
                    "VPN connect attempt=%s user_id=%s device_id=%s server_id=%s protocol=%s",
                    attempt + 1,
                    getattr(user, "id", None),
                    device_id,
                    server_id,
                    protocol,
                )
                server = self._vpn.validate_and_get_server(server_id)
                if not device_id or not str(device_id).strip():
                    if protocol in ("graniwg", "wireguard"):
                        raise HTTPException(
                            status_code=400,
                            detail="Для GraniWG/WireGuard требуется device_id",
                        )
                    return self._vpn.get_or_create_connection(user, server, protocol)

                normalized_data = {
                    "name": device_data.get("name") or f"Device {str(device_id)[:8]}",
                    "platform": device_data.get("platform") or "unknown",
                    "device_id": device_data.get("device_id") or device_id,
                }
                if device_data.get("fingerprint"):
                    normalized_data["fingerprint"] = device_data["fingerprint"]

                device = self._vpn.validate_and_get_device(
                    user,
                    str(device_id),
                    auto_register=True,
                    device_data=normalized_data,
                )
                return self._vpn.connect_device(user, device, server, protocol)
            except Exception as e:
                last_error = e
                if attempt < MAX_RETRIES:
                    time.sleep(INITIAL_DELAY * (BACKOFF ** attempt))
        elapsed = int((time.monotonic() - start) * 1000)
        logger.warning(
            "VPN connect failed user_id=%s device_id=%s server_id=%s elapsed_ms=%s",
            getattr(user, "id", None),
            device_id,
            server_id,
            elapsed,
        )
        raise last_error

    def disconnect_vpn(self, user, device_id: str, server_id=None, client_id=None, force=False):
        last_error = None
        for attempt in range(MAX_RETRIES + 1):
            try:
                if device_id:
                    device = self._vpn.validate_and_get_device(user, str(device_id))
                    return self._vpn.disconnect_device(user, device, force=bool(force))
                if client_id:
                    return self._vpn.disconnect_by_client_id(user, str(client_id), force=bool(force))
                raise HTTPException(status_code=400, detail="Укажите device_id или client_id")
            except Exception as e:
                last_error = e
                if attempt < MAX_RETRIES:
                    time.sleep(INITIAL_DELAY * (BACKOFF ** attempt))
        raise last_error

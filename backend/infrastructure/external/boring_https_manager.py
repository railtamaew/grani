"""
Менеджер для протокола Boring HTTPS (сценарий 4 обхода блокировок).

Генерирует конфиг для мобильного клиента: endpoint_url, SNI, токен в заголовках.
Серверная часть (gateway) — отдельный сервис; здесь только генерация конфига.
"""
import logging
import secrets
from typing import Dict, Any, Optional
from urllib.parse import urlparse

from domain.models.server import Server
from domain.models.user import Device
from core.config import settings

logger = logging.getLogger(__name__)


class BoringHttpsManager:
    """Генерация конфигурации клиента для туннеля Boring HTTPS."""

    def __init__(self, server: Optional[Server] = None):
        self.server = server

    def generate_config(self, device: Device, server: Server) -> Dict[str, Any]:
        """
        Генерирует конфиг для подключения по Boring HTTPS.

        Returns:
            dict: protocol, endpoint_url, sni, headers (Authorization: Bearer <token>), ttl_seconds
        """
        endpoint_url = (
            getattr(server, "boring_https_gateway_url", None)
            or settings.boring_https_gateway_url
            or ""
        ).strip()
        if not endpoint_url:
            raise ValueError(
                "Boring HTTPS gateway URL не задан. "
                "Укажите boring_https_gateway_url в настройках или на сервере."
            )

        parsed = urlparse(endpoint_url)
        if not parsed.scheme or not parsed.netloc:
            raise ValueError(f"Некорректный Boring HTTPS gateway URL: {endpoint_url}")

        sni = (
            getattr(server, "boring_https_sni", None)
            or settings.boring_https_sni
            or parsed.hostname
            or ""
        )

        token = secrets.token_urlsafe(32)
        headers = {
            "Authorization": f"Bearer {token}",
        }

        config = {
            "protocol": "boring_https",
            "endpoint_url": endpoint_url,
            "sni": sni,
            "headers": headers,
            "ttl_seconds": 3600,
        }
        logger.info(
            f"Сгенерирован конфиг Boring HTTPS для device_id={device.id}, server_id={server.id}"
        )
        return config

from sqlalchemy.orm import Session
from datetime import datetime
from typing import Dict, Any, List
from domain.models.server import Server
from core.constants import XRAY_VLESS_DEFAULT_PORT
from domain.models.protocol import Protocol

class AppConfigService:
    """Сервис для генерации конфигурации приложений"""
    
    def __init__(self, db: Session):
        self.db = db
    
    def get_app_config(self) -> Dict[str, Any]:
        """
        Генерирует конфигурацию для мобильных приложений
        
        Returns:
            Dict с конфигурацией: серверы, протоколы, feature flags, минимальные версии
        """
        # Получаем активные серверы
        servers = self.db.query(Server).filter(
            Server.is_active == True,
            Server.status.in_(["online", "draining"])  # Исключаем maintenance и offline
        ).all()
        
        servers_config = []
        for server in servers:
            server_config = {
                "id": server.id,
                "name": server.name,
                "country": server.country,
                "city": server.city,
                "ip": server.ip_address,
                "protocols": server.get_supported_protocols(),
                "weight": server.capacity or 100,  # Приоритет выдачи
                "status": server.status
            }
            
            # Добавляем параметры подключения для каждого протокола
            connection_params = {}
            
            if "wireguard" in server.get_supported_protocols():
                connection_params["wireguard"] = {
                    "port": server.wireguard_port,
                    "public_key": server.wireguard_public_key,
                    "endpoint": f"{server.ip_address}:{server.wireguard_port}"
                }
            
            if "xray_vless" in server.get_supported_protocols() or "xray_vmess" in server.get_supported_protocols():
                connection_params["xray"] = {
                    "port": server.xray_port or XRAY_VLESS_DEFAULT_PORT,
                    "domain": server.domain or server.ip_address
                }
            
            if "openvpn" in server.get_supported_protocols():
                connection_params["openvpn"] = {
                    "port": server.openvpn_port or 1194
                }
            
            server_config["connection_params"] = connection_params
            servers_config.append(server_config)
        
        # Получаем активные протоколы
        protocols = self.db.query(Protocol).filter(
            Protocol.status == "enabled"
        ).all()
        
        protocols_config = []
        for protocol in protocols:
            protocol_config = {
                "code": protocol.code,
                "name": protocol.name,
                "app_supported": protocol.app_supported or [],
                "config_schema": protocol.config_schema or {}
            }
            protocols_config.append(protocol_config)
        
        # Feature flags (можно расширить)
        feature_flags = {
            "wireguard_enabled": any("wireguard" in s.get_supported_protocols() for s in servers),
            "xray_enabled": any("xray_vless" in s.get_supported_protocols() or "xray_vmess" in s.get_supported_protocols() for s in servers),
            "openvpn_enabled": any("openvpn" in s.get_supported_protocols() for s in servers)
        }
        
        # Минимальные версии приложений (можно хранить в БД или конфиге)
        min_versions = {
            "android": "1.0.0",
            "ios": "1.0.0"
        }
        
        return {
            "servers": servers_config,
            "protocols": protocols_config,
            "feature_flags": feature_flags,
            "min_versions": min_versions,
            "updated_at": datetime.utcnow().isoformat()
        }


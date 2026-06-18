import subprocess
import os
import logging
from typing import Dict, Any, Optional
from datetime import datetime

from core.config import settings
from models.user import Device
from models.server import Server
# Опциональный импорт RemoteVPNManager
try:
    from services.remote_vpn_manager import RemoteVPNManager
    REMOTE_VPN_MANAGER_AVAILABLE = True
except ImportError:
    RemoteVPNManager = None
    REMOTE_VPN_MANAGER_AVAILABLE = False

logger = logging.getLogger(__name__)

class OpenVPNManager:
    """Менеджер для работы с OpenVPN (локальные и удаленные серверы)"""
    
    def __init__(self, server: Optional[Server] = None):
        self.server = server
        self.config_path = settings.OPENVPN_CONFIG_PATH if hasattr(settings, 'OPENVPN_CONFIG_PATH') else '/etc/openvpn/server.conf'
        self.clients_dir = settings.OPENVPN_CLIENTS_DIR if hasattr(settings, 'OPENVPN_CLIENTS_DIR') else '/etc/openvpn/clients'
        if REMOTE_VPN_MANAGER_AVAILABLE and RemoteVPNManager:
            self.remote_manager = RemoteVPNManager()
        else:
            self.remote_manager = None
            logger.warning("OpenVPNManager инициализирован без RemoteVPNManager. Удаленные серверы недоступны.")
    
    def _is_local_server(self, server: Optional[Server] = None) -> bool:
        """Проверяет, является ли сервер локальным"""
        target_server = server or self.server
        if not target_server:
            return True
        return getattr(target_server, 'is_local', False) == True
    
    def _get_config_path(self, server: Optional[Server] = None) -> str:
        """Получает путь к конфигурации OpenVPN"""
        target_server = server or self.server
        if target_server and not self._is_local_server(target_server):
            return getattr(target_server, 'openvpn_config_path', '/etc/openvpn/server.conf')
        return self.config_path
    
    def generate_client_config(self, device: Device, server: Server, cloak_config: Dict[str, Any]) -> str:
        """Генерирует конфигурацию OpenVPN клиента с Cloak"""
        try:
            # Если сервер удаленный, используем RemoteVPNManager
            if not self._is_local_server(server):
                return self.remote_manager.generate_openvpn_config(server, device, cloak_config)
            
            # Локальный сервер - генерируем конфиг
            port = server.openvpn_port or 1194
            cloak_uid = cloak_config.get('uid', '')
            cloak_public_key = cloak_config.get('publicKey', '')
            cloak_mask_site = cloak_config.get('maskSite', 'google.com')
            
            # Базовая конфигурация OpenVPN
            config = f"""# OpenVPN over Cloak Configuration
# Generated for device {device.id} - {device.device_name or device.device_id}
# Server: {server.name} ({server.ip_address}:{port})

client
dev tun
proto tcp
remote {server.ip_address} {port}
resolv-retry infinite
nobind
persist-key
persist-tun
verb 3

# Cloak plugin configuration
<plugin>
  /usr/local/bin/ck-client
  -U
  -l {cloak_uid}
  -k {cloak_public_key}
  -b
  -c {cloak_mask_site}
</plugin>

# Certificate and key will be provided separately
<ca>
# CA certificate will be inserted here
</ca>

<cert>
# Client certificate will be inserted here
</cert>

<key>
# Client private key will be inserted here
</key>

# Additional settings
cipher AES-256-GCM
auth SHA256
compress lz4-v2
"""
            
            logger.info(f"Сгенерирована OpenVPN over Cloak конфигурация для устройства {device.id}")
            return config
            
        except Exception as e:
            logger.error(f"Ошибка генерации OpenVPN конфигурации: {e}")
            raise
    
    def create_client_certificate(self, device: Device, server: Server) -> Dict[str, str]:
        """Создает сертификат и ключ для клиента"""
        try:
            # Если сервер удаленный, используем RemoteVPNManager
            if not self._is_local_server(server):
                return self.remote_manager.create_openvpn_client_cert(server, device)
            
            # Локальный сервер - используем easy-rsa или openssl
            # Генерируем сертификат клиента
            client_name = f"client_{device.id}_{device.user_id}"
            
            # Используем easy-rsa для генерации сертификатов
            easyrsa_path = '/usr/share/easy-rsa'
            if not os.path.exists(easyrsa_path):
                easyrsa_path = '/etc/easy-rsa'
            
            # Генерируем ключ и запрос на сертификат
            # В реальной реализации здесь будет полная генерация сертификатов
            # Для упрощения возвращаем заглушку
            logger.warning("Генерация OpenVPN сертификатов требует настройки easy-rsa. Возвращаем заглушку.")
            
            return {
                'ca_cert': '# CA certificate placeholder',
                'client_cert': '# Client certificate placeholder',
                'client_key': '# Client private key placeholder'
            }
            
        except Exception as e:
            logger.error(f"Ошибка создания сертификата клиента: {e}")
            raise



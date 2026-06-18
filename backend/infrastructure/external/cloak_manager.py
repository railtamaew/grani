import subprocess
import os
import json
import logging
from typing import Dict, Any, Optional
from datetime import datetime

from core.config import settings
from domain.models.server import Server

logger = logging.getLogger(__name__)

class CloakManager:
    """Менеджер для работы с Cloak плагином"""
    
    def __init__(self, server: Optional[Server] = None):
        self.server = server
        self.cloak_bin = '/usr/local/bin/ck-server'  # Путь к ck-server
        self.cloak_config_path = '/etc/cloak/config.json'
    
    def _is_local_server(self, server: Optional[Server] = None) -> bool:
        """Проверяет, является ли сервер локальным"""
        target_server = server or self.server
        if not target_server:
            return True
        return getattr(target_server, 'is_local', False) == True
    
    def get_cloak_config(self, server: Server) -> Dict[str, Any]:
        """Получает конфигурацию Cloak для сервера"""
        if not server.cloak_enabled:
            raise Exception("Cloak не включен на сервере")
        
        cloak_config = server.get_cloak_config()
        if not cloak_config.get('uid') or not cloak_config.get('publicKey'):
            raise Exception("Конфигурация Cloak неполная. Требуются uid и publicKey")
        
        return cloak_config
    
    def generate_cloak_config_file(self, server: Server) -> str:
        """Генерирует конфигурационный файл Cloak для сервера"""
        cloak_config = self.get_cloak_config(server)
        
        config = {
            "ProxyBook": {
                "shadowsocks": ["tcp", "127.0.0.1:8388"]
            },
            "BindAddr": ["0.0.0.0:443"],
            "BypassUID": [cloak_config.get('bypassUid', '')],
            "RedirAddr": cloak_config.get('maskSite', 'google.com'),
            "PrivateKey": cloak_config.get('privateKey', ''),
            "AdminUID": cloak_config.get('adminUid', ''),
            "DatabasePath": "/etc/cloak/userinfo.db",
            "StreamTimeout": 300
        }
        
        return json.dumps(config, indent=2)
    
    def validate_cloak_config(self, server: Server) -> bool:
        """Проверяет валидность конфигурации Cloak"""
        try:
            cloak_config = self.get_cloak_config(server)
            
            # Проверяем наличие обязательных полей
            required_fields = ['uid', 'publicKey', 'maskSite']
            for field in required_fields:
                if not cloak_config.get(field):
                    logger.warning(f"Отсутствует обязательное поле Cloak: {field}")
                    return False
            
            return True
        except Exception as e:
            logger.error(f"Ошибка валидации Cloak конфигурации: {e}")
            return False



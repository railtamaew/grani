from sqlalchemy import Column, Integer, String, Boolean, DateTime, Text, ForeignKey, Float, JSON
from sqlalchemy.orm import relationship
from datetime import datetime
from core.database import Base
from core.constants import (
    DEFAULT_MAX_USERS_PER_SERVER,
    WIREGUARD_DEFAULT_PORT
)
from typing import TYPE_CHECKING
import json

if TYPE_CHECKING:
    from models.user import User, Device

class Server(Base):
    __tablename__ = "servers"
    
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, nullable=False)
    ip_address = Column(String, nullable=False)
    country = Column(String, nullable=False)
    city = Column(String, nullable=True)
    is_active = Column(Boolean, default=True)
    max_users = Column(Integer, default=DEFAULT_MAX_USERS_PER_SERVER)
    current_users = Column(Integer, default=0)
    wireguard_port = Column(Integer, default=WIREGUARD_DEFAULT_PORT)
    wireguard_public_key = Column(String, nullable=True)
    wireguard_private_key = Column(String, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    # Новые поля для мониторинга и провайдеров
    provider = Column(String, nullable=True)  # DigitalOcean, AWS, Hetzner, etc.
    provider_region = Column(String, nullable=True)  # us-east-1, eu-central-1, etc.
    server_specs = Column(JSON, nullable=True)  # {"cpu": "4 cores", "ram": "8GB", "bandwidth": "1TB"}
    supported_protocols = Column(JSON, nullable=True)  # ["wireguard"]
    xray_port = Column(Integer, nullable=True)  # Порт для Xray (обычно 443)
    openvpn_port = Column(Integer, nullable=True)  # Порт для OpenVPN
    openvpn_config_path = Column(String, nullable=True)  # Путь к конфигурации OpenVPN
    
    # Поля для GRANIWG (обфусцированный WireGuard)
    graniwg_enabled = Column(Boolean, default=False)  # Включен ли GRANIWG
    graniwg_obfuscation_key = Column(String, nullable=True)  # Ключ обфускации для GRANIWG
    graniwg_obfuscation_type = Column(String, nullable=True)  # Тип обфускации (например, "udp2raw")
    
    # Поля для XRay Reality
    reality_enabled = Column(Boolean, default=False)  # Включен ли REALITY
    reality_short_id = Column(String, nullable=True)  # Short ID для REALITY (например, "6ba85179e30d4fc2")
    reality_server_name = Column(String, nullable=True)  # Имя сервера для маскировки (например, "google.com")
    reality_dest = Column(String, nullable=True)  # Dest для REALITY (например, "google.com:443")
    reality_sni = Column(String, nullable=True)  # SNI для REALITY (например, "google.com")
    reality_private_key = Column(String, nullable=True)  # Приватный ключ для REALITY
    reality_public_key = Column(String, nullable=True)  # Публичный ключ для REALITY
    
    # Поля для OpenVPN over Cloak
    cloak_enabled = Column(Boolean, default=False)  # Включен ли Cloak
    cloak_uid = Column(String, nullable=True)  # UID для Cloak
    cloak_public_key = Column(String, nullable=True)  # Публичный ключ Cloak
    cloak_private_key = Column(String, nullable=True)  # Приватный ключ Cloak
    cloak_mask_site = Column(String, nullable=True)  # Сайт для маскировки (например, "google.com")
    cloak_admin_uid = Column(String, nullable=True)  # Admin UID для Cloak
    cloak_bypass_uid = Column(String, nullable=True)  # Bypass UID для Cloak
    
    load_percentage = Column(Float, default=0.0)  # Текущая загрузка в процентах
    bandwidth_used_mbps = Column(Float, default=0.0)  # Использованная пропускная способность
    bandwidth_limit_mbps = Column(Float, nullable=True)  # Лимит пропускной способности
    ping_ms = Column(Float, nullable=True)  # Средний ping до сервера
    uptime_percentage = Column(Float, default=100.0)  # Процент времени работы
    last_health_check = Column(DateTime, nullable=True)  # Последняя проверка здоровья
    health_status = Column(String, default="unknown")  # healthy, warning, error
    protocol_performance = Column(JSON, nullable=True)  # Статистика по протоколам
    domain = Column(String, nullable=True)  # Доменное имя сервера (для Xray)
    
    # Новые поля для управления статусом сервера
    status = Column(String, default="online")  # online, offline, draining, maintenance
    capacity = Column(Integer, nullable=True)  # Вес/приоритет для выдачи новым пользователям
    
    # Поля для SSH доступа к удаленным VPN серверам
    ssh_host = Column(String, nullable=True)  # IP адрес или hostname VPN сервера (если отличается от ip_address)
    ssh_port = Column(Integer, default=22)  # SSH порт
    ssh_user = Column(String, default="root")  # SSH пользователь
    ssh_key_path = Column(String, nullable=True)  # Путь к SSH ключу на backend сервере
    ssh_key_content = Column(Text, nullable=True)  # Содержимое SSH ключа (зашифрованное, опционально)
    ssh_password = Column(Text, nullable=True)  # SSH пароль (временный, для тестирования, должен быть удален в продакшене)
    
    # Поля для конфигурации VPN на удаленных серверах
    wireguard_config_path = Column(String, default="/etc/wireguard/wg0.conf")  # Путь к конфигурации WireGuard на VPN сервере
    wireguard_interface = Column(String, default="wg0")  # Имя интерфейса WireGuard
    xray_config_path = Column(String, default="/etc/xray/config.json")  # Путь к конфигурации Xray на VPN сервере
    is_local = Column(Boolean, default=False)  # Флаг, является ли сервер локальным (на backend сервере)

    # Edge-агент (фаза 1): pull heartbeat с ноды, без SSH для рутины
    edge_agent_token_hash = Column(String(128), nullable=True, index=True)
    edge_last_heartbeat_at = Column(DateTime, nullable=True)
    edge_reported_config_hash = Column(String(256), nullable=True)
    edge_agent_version = Column(String(64), nullable=True)

    # Свойство для совместимости с кодом, использующим server.port
    @property
    def port(self) -> int:
        return self.wireguard_port
    
    @property
    def public_key(self) -> str:
        return self.wireguard_public_key or ""
    
    def get_server_specs(self) -> dict:
        """Получает характеристики сервера в виде словаря"""
        if self.server_specs:
            if isinstance(self.server_specs, str):
                return json.loads(self.server_specs)
            return self.server_specs
        return {}
    
    def set_server_specs(self, specs: dict):
        """Устанавливает характеристики сервера"""
        self.server_specs = specs
    
    def get_supported_protocols(self) -> list:
        """Получает список поддерживаемых протоколов"""
        protocols = []
        if self.supported_protocols:
            if isinstance(self.supported_protocols, str):
                protocols = json.loads(self.supported_protocols)
            else:
                protocols = list(self.supported_protocols)
        else:
            protocols = ["wireguard"]  # По умолчанию только WireGuard

        protocols_set = set(protocols)

        # GRANIWG добавляем по флагу
        if self.graniwg_enabled:
            protocols_set.add("graniwg")

        # Xray добавляем, если есть признаки конфигурации
        has_xray = bool(self.xray_port or self.xray_config_path or self.reality_enabled)
        if has_xray:
            protocols_set.add("xray_vless")
            protocols_set.add("xray_vmess")
            protocols_set.add("xray_vless_ws_tls")
            protocols_set.add("xray_vless_grpc_tls")

        if self.reality_enabled:
            protocols_set.add("xray_reality")

        return sorted(protocols_set)
    
    def set_supported_protocols(self, protocols: list):
        """Устанавливает список поддерживаемых протоколов"""
        self.supported_protocols = protocols
    
    def get_protocol_performance(self) -> dict:
        """Получает статистику по протоколам"""
        if self.protocol_performance:
            if isinstance(self.protocol_performance, str):
                return json.loads(self.protocol_performance)
            return self.protocol_performance
        return {}
    
    def set_protocol_performance(self, performance: dict):
        """Устанавливает статистику по протоколам"""
        self.protocol_performance = performance
    
    def get_reality_config(self) -> dict:
        """Получает конфигурацию REALITY"""
        if not self.reality_enabled:
            return {}
        return {
            "shortId": self.reality_short_id or "",
            "serverName": self.reality_server_name or "",
            "dest": self.reality_dest or "",
            "sni": self.reality_sni or self.reality_server_name or "",
            "privateKey": self.reality_private_key or "",
            "publicKey": self.reality_public_key or ""
        }
    
    def get_graniwg_config(self) -> dict:
        """Получает конфигурацию GRANIWG"""
        if not self.graniwg_enabled:
            return {}
        return {
            "obfuscationKey": self.graniwg_obfuscation_key or "",
            "obfuscationType": self.graniwg_obfuscation_type or "udp2raw"
        }
    
    def get_cloak_config(self) -> dict:
        """Получает конфигурацию Cloak"""
        if not self.cloak_enabled:
            return {}
        return {
            "uid": self.cloak_uid or "",
            "publicKey": self.cloak_public_key or "",
            "privateKey": self.cloak_private_key or "",
            "maskSite": self.cloak_mask_site or "",
            "adminUid": self.cloak_admin_uid or "",
            "bypassUid": self.cloak_bypass_uid or ""
        }
    
    # Связи (отключаем lazy loading для избежания проблем с инициализацией)
    connection_logs = relationship("ConnectionLog", back_populates="server", lazy="noload")

class ConnectionLog(Base):
    __tablename__ = "connection_logs"
    
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    device_id = Column(Integer, ForeignKey("devices.id"), nullable=False)
    server_id = Column(Integer, ForeignKey("servers.id"), nullable=False)
    connection_type = Column(String, default="connect")  # connect, disconnect
    ip_address = Column(String, nullable=True)
    user_agent = Column(String, nullable=True)
    connected_at = Column(DateTime, default=datetime.utcnow)
    disconnected_at = Column(DateTime, nullable=True)
    duration_seconds = Column(Integer, nullable=True)
    vpn_session_id = Column(String, nullable=True, index=True)
    
    # Связи (используем строковые имена для избежания циклических импортов)
    user = relationship("User", back_populates="connection_logs", lazy="select")
    device = relationship("Device", back_populates="connection_logs", lazy="select")
    server = relationship("Server", back_populates="connection_logs", lazy="select")










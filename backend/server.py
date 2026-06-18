from sqlalchemy import Column, Integer, String, Boolean, DateTime, Text, ForeignKey, Float, JSON
from sqlalchemy.orm import relationship
from datetime import datetime
from core.database import Base
import json

class Server(Base):
    __tablename__ = "servers"
    
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, nullable=False)
    ip_address = Column(String, nullable=False)
    country = Column(String, nullable=False)
    city = Column(String, nullable=True)
    is_active = Column(Boolean, default=True)
    max_users = Column(Integer, default=1000)
    current_users = Column(Integer, default=0)
    wireguard_port = Column(Integer, default=51820)
    wireguard_public_key = Column(String, nullable=True)
    wireguard_private_key = Column(String, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    # Новые поля для мониторинга и провайдеров
    provider = Column(String, nullable=True)  # DigitalOcean, AWS, Hetzner, etc.
    provider_region = Column(String, nullable=True)  # us-east-1, eu-central-1, etc.
    server_specs = Column(JSON, nullable=True)  # {"cpu": "4 cores", "ram": "8GB", "bandwidth": "1TB"}
    supported_protocols = Column(JSON, nullable=True)  # ["wireguard", "xray_vless", "xray_vmess"]
    xray_port = Column(Integer, nullable=True)  # Порт для Xray (обычно 443)
    xray_config_path = Column(String, nullable=True)  # Путь к конфигурации Xray
    openvpn_port = Column(Integer, nullable=True)  # Порт для OpenVPN
    load_percentage = Column(Float, default=0.0)  # Текущая загрузка в процентах
    bandwidth_used_mbps = Column(Float, default=0.0)  # Использованная пропускная способность
    bandwidth_limit_mbps = Column(Float, nullable=True)  # Лимит пропускной способности
    ping_ms = Column(Float, nullable=True)  # Средний ping до сервера
    uptime_percentage = Column(Float, default=100.0)  # Процент времени работы
    last_health_check = Column(DateTime, nullable=True)  # Последняя проверка здоровья
    health_status = Column(String, default="unknown")  # healthy, warning, error
    protocol_performance = Column(JSON, nullable=True)  # Статистика по протоколам
    domain = Column(String, nullable=True)  # Доменное имя сервера (для Xray)
    
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
        if self.supported_protocols:
            if isinstance(self.supported_protocols, str):
                return json.loads(self.supported_protocols)
            return self.supported_protocols
        return ["wireguard"]  # По умолчанию только WireGuard
    
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
    
    # Связи
    connection_logs = relationship("ConnectionLog", back_populates="server")

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
    
    # Связи
    user = relationship("User", back_populates="connection_logs")
    device = relationship("Device", back_populates="connection_logs")
    server = relationship("Server", back_populates="connection_logs")










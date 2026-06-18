from sqlalchemy import Column, Integer, String, Float, Date, ForeignKey, DateTime
from sqlalchemy.orm import relationship
from datetime import datetime, date
from core.database import Base

class ProtocolStats(Base):
    """Статистика по протоколам VPN"""
    __tablename__ = "protocol_stats"
    
    id = Column(Integer, primary_key=True, index=True)
    server_id = Column(Integer, ForeignKey("servers.id"), nullable=False, index=True)
    protocol = Column(String, nullable=False, index=True)  # wireguard, xray_vless, xray_vmess, openvpn
    date = Column(Date, default=date.today, nullable=False, index=True)
    
    # Статистика подключений
    total_connections = Column(Integer, default=0)
    successful_connections = Column(Integer, default=0)
    failed_connections = Column(Integer, default=0)
    
    # Производительность
    average_speed_mbps = Column(Float, default=0.0)
    average_ping_ms = Column(Float, default=0.0)
    total_traffic_gb = Column(Float, default=0.0)
    
    # Надежность
    uptime_percentage = Column(Float, default=100.0)
    user_satisfaction_score = Column(Float, default=0.0)  # 0-10
    
    # Метаданные
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    # Связи
    server = relationship("Server", backref="protocol_stats")
    
    def get_success_rate(self) -> float:
        """Вычисляет процент успешных подключений"""
        if self.total_connections == 0:
            return 0.0
        return (self.successful_connections / self.total_connections) * 100
    
    def get_failure_rate(self) -> float:
        """Вычисляет процент неудачных подключений"""
        if self.total_connections == 0:
            return 0.0
        return (self.failed_connections / self.total_connections) * 100


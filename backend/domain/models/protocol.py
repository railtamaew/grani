from sqlalchemy import Column, Integer, String, Boolean, DateTime, Text, JSON, Index
from sqlalchemy.orm import relationship
from datetime import datetime
from core.database import Base

class Protocol(Base):
    __tablename__ = "protocols"
    
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, nullable=False)  # WireGuard, AmneziaWG, OpenVPN
    code = Column(String, unique=True, nullable=False, index=True)  # wg, awg, openvpn
    status = Column(String, default="enabled")  # enabled, disabled, deprecated, testing
    app_supported = Column(JSON, nullable=True)  # ["android", "ios", "web"]
    config_schema = Column(JSON, nullable=True)  # Параметры конфигурации
    release_notes = Column(Text, nullable=True)  # Что изменилось
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    # Связи - временно отключены из-за проблем с primaryjoin без foreign key
    # telemetry_events = relationship("TelemetryEvent", back_populates="protocol_rel")
    # protocol_stats = relationship("ProtocolStats", back_populates="protocol")


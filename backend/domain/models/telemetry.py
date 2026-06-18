from sqlalchemy import Column, Integer, String, Boolean, DateTime, Text, ForeignKey, Float, JSON, Index
from sqlalchemy.orm import relationship
from datetime import datetime
from core.database import Base

class TelemetryEvent(Base):
    __tablename__ = "telemetry_events"
    
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=True, index=True)  # Может быть null для анонимных пользователей
    device_id = Column(Integer, ForeignKey("devices.id"), nullable=True)
    protocol_code = Column(String, nullable=True, index=True)  # Код протокола (wg, awg, etc.)
    server_id = Column(Integer, ForeignKey("servers.id"), nullable=True, index=True)
    event_type = Column(String, nullable=False)  # connect_start, connect_success, connect_fail, disconnect, handshake_fail, dns_fail, timeout, auth_fail, server_unreachable
    timestamp = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    duration_ms = Column(Integer, nullable=True)  # Длительность события в миллисекундах
    error_code = Column(String, nullable=True, index=True)  # Нормализованный код ошибки
    error_message = Column(String, nullable=True)  # Короткое сообщение об ошибке
    network_type = Column(String, nullable=True)  # wifi, 4g, 5g
    ip = Column(String, nullable=True)  # IP адрес пользователя
    country = Column(String, nullable=True)  # Страна пользователя
    status = Column(String, default="new")  # new, investigating, resolved, ignored - для инцидентов
    app_version = Column(String, nullable=True)  # Версия приложения
    os_version = Column(String, nullable=True)  # Версия ОС
    platform = Column(String, nullable=True)  # android, ios, etc.
    vpn_session_id = Column(String, nullable=True, index=True)  # Сквозной ID VPN-сессии
    
    # Связи
    user = relationship("User", foreign_keys=[user_id])
    device = relationship("Device", foreign_keys=[device_id])
    server = relationship("Server", foreign_keys=[server_id])
    # Связь с Protocol через code временно отключена из-за проблем с primaryjoin без foreign key
    # protocol_rel = relationship("Protocol", primaryjoin="TelemetryEvent.protocol_code == Protocol.code", viewonly=True)

# Индексы для оптимизации запросов
Index('idx_telemetry_user_device', TelemetryEvent.user_id, TelemetryEvent.device_id)
Index('idx_telemetry_timestamp_status', TelemetryEvent.timestamp, TelemetryEvent.status)
Index('idx_telemetry_error', TelemetryEvent.error_code, TelemetryEvent.timestamp)


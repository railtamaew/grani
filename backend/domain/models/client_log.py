from sqlalchemy import Column, Integer, String, Boolean, DateTime, ForeignKey, Text, JSON
from sqlalchemy.orm import relationship
from datetime import datetime
from core.database import Base
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from models.user import User, Device
    from models.server import Server

class ClientLog(Base):
    """Детальные логи подключений от клиентов для мониторинга и отладки"""
    __tablename__ = "client_logs"
    
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    device_id = Column(Integer, ForeignKey("devices.id"), nullable=False, index=True)
    server_id = Column(Integer, ForeignKey("servers.id"), nullable=True, index=True)
    
    # Тип события
    event_type = Column(String, nullable=False, index=True)  # connection_start, connection_success, connection_error, connection_end, protocol_error, etc.
    
    # Протокол и детали подключения
    protocol = Column(String, nullable=True, index=True)  # wireguard, xray_vless, xray_vmess, xray_reality, etc.
    client_id = Column(String, nullable=True)  # VPN client ID (например, vless_1_1)
    
    # Детали ошибки/события
    message = Column(Text, nullable=True)  # Сообщение об ошибке или событии
    error_code = Column(String, nullable=True)  # Код ошибки (если есть)
    error_details = Column(JSON, nullable=True)  # Дополнительные детали в JSON формате
    
    # Техническая информация
    app_version = Column(String, nullable=True)  # Версия приложения
    platform = Column(String, nullable=True)  # android, ios
    os_version = Column(String, nullable=True)  # Версия ОС
    
    # Метрики подключения (если доступны)
    connection_duration_ms = Column(Integer, nullable=True)  # Длительность подключения в миллисекундах
    bytes_sent = Column(Integer, nullable=True)  # Отправлено байт
    bytes_received = Column(Integer, nullable=True)  # Получено байт
    vpn_session_id = Column(String, nullable=True, index=True)  # Сквозной ID VPN-сессии
    
    # Временные метки
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    
    # Связи
    user = relationship("User", backref="client_logs")
    device = relationship("Device", backref="client_logs")
    server = relationship("Server", backref="client_logs")

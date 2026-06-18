"""
Модель VPN-соединения на уровне (user, server, protocol).
Один коннект на тройку — для единого алгоритма подключений без обязательного device_id.
"""
from sqlalchemy import Column, Integer, String, DateTime, ForeignKey, Index
from sqlalchemy.orm import relationship
from datetime import datetime

from core.database import Base


class UserVpnConnection(Base):
    """
    Одна запись на (user_id, server_id, protocol).
    XRay: vpn_client_id, vpn_protocol.
    WireGuard/GRANIWG: wireguard_public_key, wireguard_private_key, ip_address, connection_id.
    """
    __tablename__ = "user_vpn_connections"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    server_id = Column(Integer, ForeignKey("servers.id", ondelete="CASCADE"), nullable=False)
    protocol = Column(String(64), nullable=False)  # xray_vless, xray_vmess, xray_reality, wireguard, graniwg

    # XRay
    vpn_client_id = Column(String(128), nullable=True)   # UUID с сервера
    vpn_protocol = Column(String(32), nullable=True)     # vless, vmess, reality

    # WireGuard / GRANIWG
    wireguard_public_key = Column(String(128), nullable=True)
    wireguard_private_key = Column(String(128), nullable=True)
    ip_address = Column(String(64), nullable=True)
    connection_id = Column(String(64), nullable=True, index=True)  # наш UUID для GET /config

    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    user = relationship("User", backref="vpn_connections")
    server = relationship("Server", backref="user_vpn_connections")

    __table_args__ = (
        Index("ix_user_vpn_connections_user_server_protocol", "user_id", "server_id", "protocol", unique=True),
    )

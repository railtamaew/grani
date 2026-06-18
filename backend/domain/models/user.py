from sqlalchemy import Column, Integer, String, Boolean, DateTime, ForeignKey, Text, Enum as SQLEnum, Index
from sqlalchemy.orm import relationship, synonym
from datetime import datetime
from core.database import Base
import enum

class UserRole(str, enum.Enum):
    """Роли пользователей в админ-панели"""
    OWNER = "owner"
    ADMIN = "admin"
    SUPPORT = "support"
    READ_ONLY = "read_only"

class User(Base):
    __tablename__ = "users"
    
    id = Column(Integer, primary_key=True, index=True)
    email = Column(String, unique=True, index=True, nullable=False)
    password_hash = Column(String, nullable=True)
    is_active = Column(Boolean, default=True)
    is_verified = Column(Boolean, default=False)
    auth_provider = Column(String, default="email")  # email, google и т.д.
    provider_uid = Column(String, nullable=True)  # external sub/uid
    verification_code = Column(String, nullable=True)
    verification_code_expires = Column(DateTime, nullable=True)
    last_verification_sent_at = Column(DateTime, nullable=True)
    verification_attempts = Column(Integer, default=0)
    daily_code_sent = Column(Integer, default=0)
    daily_code_sent_reset_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    last_login_at = Column(DateTime, nullable=True)
    
    # Поля для триала
    trial_active = Column(Boolean, default=False)  # Активен ли триал
    trial_seconds_left = Column(Integer, default=0)  # Оставшееся время триала в секундах
    trial_started_at = Column(DateTime, nullable=True)  # Когда начался триал
    
    # Новые поля для админ-панели
    role = Column(SQLEnum(UserRole), nullable=True, default=None)  # Роль в админ-панели (owner/admin/support/read_only)
    country = Column(String, nullable=True)  # Страна пользователя (из GeoIP/приложения)
    last_seen_at = Column(DateTime, nullable=True)  # Последний раз был онлайн
    notes = Column(Text, nullable=True)  # Заметки саппорта
    # Push-уведомления (FCM-токен последнего активного устройства пользователя)
    push_token = Column(String, nullable=True)
    # Язык интерфейса/коммуникаций пользователя (en/ru)
    preferred_language = Column(String(8), nullable=False, default="en")
    
    # Связи
    subscriptions = relationship("Subscription", back_populates="user")
    # devices relationship - используем primaryjoin для явного указания связи
    devices = relationship("Device", back_populates="user", primaryjoin="User.id == Device.user_id")
    payments = relationship("Payment", back_populates="user")
    connection_logs = relationship("ConnectionLog", back_populates="user")
    admin_login_logs = relationship("AdminLoginLog", back_populates="user")

class Device(Base):
    __tablename__ = "devices"
    
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    device_id = Column(String, nullable=False)  # Уникальный ID устройства
    device_name = Column(String, nullable=True)
    device_type = Column(String, nullable=True)  # ios, android, desktop
    wireguard_public_key = Column(String, nullable=True)
    wireguard_private_key = Column(String, nullable=True)
    is_active = Column(Boolean, default=True)
    last_connected = Column(DateTime, nullable=True)
    current_server_id = Column(Integer, nullable=True)  # ID текущего подключенного сервера
    ip_address = Column(String, nullable=True)  # IP адрес устройства в VPN сети
    vpn_protocol = Column(String, nullable=True)  # Текущий VPN протокол (wireguard/xray/etc)
    vpn_client_id = Column(String, nullable=True)  # ID клиента в Xray/OpenVPN
    is_vpn_enabled = Column(Boolean, default=False)  # Включен ли VPN на устройстве
    created_at = Column(DateTime, default=datetime.utcnow)
    
    # Новые поля для расширенной информации об устройстве
    platform = Column(String, nullable=True)  # android, ios, windows, etc.
    model = Column(String, nullable=True)  # Модель устройства
    os_version = Column(String, nullable=True)  # Версия ОС
    app_version = Column(String, nullable=True)  # Версия приложения
    last_ip = Column(String, nullable=True)  # Последний IP адрес
    last_country = Column(String, nullable=True)  # Последняя страна
    push_token = Column(String, nullable=True)  # Токен для push-уведомлений
    device_fingerprint = Column(String, nullable=True, index=True)  # Хеш для resolve после переустановки (user_id + fingerprint уникальны)

    # Связи
    user = relationship("User", back_populates="devices")
    connection_logs = relationship("ConnectionLog", back_populates="device")

    __table_args__ = (Index("ix_devices_user_id_fingerprint", "user_id", "device_fingerprint"),)

    # Совместимость с legacy-полями
    public_key = synonym("wireguard_public_key")
    private_key = synonym("wireguard_private_key")










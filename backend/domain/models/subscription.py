from sqlalchemy import Column, Integer, String, Boolean, DateTime, ForeignKey, Float
from sqlalchemy.orm import relationship
from datetime import datetime
from core.database import Base


class Plan(Base):
    __tablename__ = "plans"
    
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, nullable=False)
    description = Column(String, nullable=True)
    price = Column(Float, nullable=False)
    duration_days = Column(Integer, nullable=False)
    max_speed_mbps = Column(Integer, nullable=False)
    max_devices = Column(Integer, default=2)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    google_play_product_id = Column(String, nullable=True)
    
    # Связи
    subscriptions = relationship("Subscription", back_populates="plan")


class Subscription(Base):
    __tablename__ = "subscriptions"
    
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    plan_id = Column(Integer, ForeignKey("plans.id"), nullable=False)
    status = Column(String, nullable=True)  # active, expired, cancelled, revoked
    start_date = Column(DateTime, nullable=True)
    end_date = Column(DateTime, nullable=False)
    auto_renew = Column(Boolean, default=False)
    source = Column(String(50), nullable=True)  # manual, google_play, cloudpayments, etc.
    external_id = Column(String(255), nullable=True)  # External subscription ID (order_id)
    purchase_token = Column(String(500), nullable=True)  # Google Play purchase token for RTDN
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    # Связи
    user = relationship("User", back_populates="subscriptions")
    plan = relationship("Plan", back_populates="subscriptions")

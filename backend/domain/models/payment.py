from sqlalchemy import Column, Integer, String, Boolean, DateTime, Float, ForeignKey, Text
from sqlalchemy.orm import relationship
from datetime import datetime
from core.database import Base

class Payment(Base):
    __tablename__ = "payments"
    
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    plan_id = Column(Integer, ForeignKey("plans.id"), nullable=False)
    amount = Column(Float, nullable=False)
    currency = Column(String, default="USD")
    payment_method = Column(String, nullable=False)  # cloudpayments, yukassa, payanyway
    payment_id = Column(String, nullable=True)  # ID от платежной системы
    status = Column(String, default="pending")  # pending, completed, failed, cancelled
    description = Column(Text, nullable=True)
    payment_metadata = Column(Text, nullable=True)  # JSON с дополнительными данными
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    # Связи
    user = relationship("User", back_populates="payments")
    plan = relationship("Plan")



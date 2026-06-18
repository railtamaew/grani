from sqlalchemy import Column, Integer, String, Boolean, DateTime, Text, ForeignKey, Index
from sqlalchemy.orm import relationship
from datetime import datetime
from core.database import Base

class AdminLoginLog(Base):
    __tablename__ = "admin_login_logs"
    
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    ip_address = Column(String, nullable=True)
    user_agent = Column(Text, nullable=True)
    success = Column(Boolean, default=False, nullable=False)
    failure_reason = Column(String, nullable=True)  # wrong_password, account_locked, etc.
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    
    # Связи
    user = relationship("User", back_populates="admin_login_logs")

# Индексы для оптимизации запросов (для проверки rate limiting)
Index('idx_admin_login_user_time', AdminLoginLog.user_id, AdminLoginLog.created_at)
Index('idx_admin_login_ip_time', AdminLoginLog.ip_address, AdminLoginLog.created_at)




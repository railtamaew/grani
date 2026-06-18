from sqlalchemy import Column, Integer, String, DateTime, Text, ForeignKey, JSON, Index
from sqlalchemy.orm import relationship
from datetime import datetime
from core.database import Base

class AuditLog(Base):
    __tablename__ = "audit_logs"
    
    id = Column(Integer, primary_key=True, index=True)
    admin_user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    action = Column(String, nullable=False)  # create, update, delete, enable, disable, etc.
    entity_type = Column(String, nullable=False, index=True)  # user, server, protocol, subscription, etc.
    entity_id = Column(Integer, nullable=False)  # ID измененной сущности
    old_value = Column(JSON, nullable=True)  # Старое значение (JSON)
    new_value = Column(JSON, nullable=True)  # Новое значение (JSON)
    ip_address = Column(String, nullable=True)
    user_agent = Column(Text, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    
    # Связи
    admin_user = relationship("User", foreign_keys=[admin_user_id])

# Индексы для оптимизации запросов
Index('idx_audit_admin_entity', AuditLog.admin_user_id, AuditLog.entity_type, AuditLog.created_at)




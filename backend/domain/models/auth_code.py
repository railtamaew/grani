from sqlalchemy import Column, Integer, String, DateTime, Index
from datetime import datetime
from core.database import Base


class AuthCode(Base):
    """
    Модель для хранения кодов подтверждения email.
    Коды хранятся в хэшированном виде для безопасности.
    """
    __tablename__ = "auth_codes"
    
    id = Column(Integer, primary_key=True, index=True)
    email = Column(String, nullable=False, index=True)
    code_hash = Column(String, nullable=False)  # Хэш кода (bcrypt или sha256)
    expires_at = Column(DateTime, nullable=False, index=True)
    attempts_count = Column(Integer, default=0)
    created_at = Column(DateTime, default=datetime.utcnow)
    ip_address = Column(String, nullable=True)  # IP адрес, с которого был запрошен код
    
    # Индекс для быстрого поиска по email и сроку действия
    __table_args__ = (
        Index('idx_email_expires', 'email', 'expires_at'),
    )
    
    def __repr__(self):
        return f"<AuthCode(email={self.email}, expires_at={self.expires_at}, attempts={self.attempts_count})>"










